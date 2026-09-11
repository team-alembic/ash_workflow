defmodule AshWorkflow.Scheduler do
  @moduledoc """
  The behaviour a module implements to run a workflow's scheduled work.

  A workflow declares two kinds of work: automatic steps, which should run as
  soon as a record occupies them, and timeouts, which should run once a deadline
  has passed. Both arrive as `AshWorkflow.Scheduler.Work` structs. A scheduler
  decides **when** each one runs, and how durably. It does not decide what
  running means — see "The split" below.

  ## Choosing one

      workflow do
        scheduler AshWorkflow.Scheduler.Oban, queue: :workflow, check_interval: "* * * * *"
      end

  Or once for an application:

      config :ash_workflow, scheduler: {AshWorkflow.Scheduler.Oban, queue: :workflow}

  ## The split

  The scheduler owns *when* and *how durably*. AshWorkflow owns *what happens*:
  which action runs, where a failure routes, what actor and authorization apply.
  That division is why `execute/3` lives here rather than in each
  implementation. Two schedulers must not disagree about whether `on_error`
  fires, so neither of them gets to decide.

  So an implementation's job is to arrange for `execute/3` to be called at the
  right moment, and to survive a node restart while it waits.

  ## Two strategies, one behaviour

  The interesting constraint is that the sensible implementations work in
  opposite directions.

  A **discovering** scheduler periodically asks the data layer which records
  match, and nothing is recorded per deadline. That is what the Oban
  implementation does, and its floor is the polling interval — one minute for
  cron. It reads `Work.match` and ignores `c:deadline_changed/2`.

  A **registering** scheduler is told each deadline as it becomes known and arms
  a timer for it. Its floor is the timer, which is microseconds. It reads
  `Work.deadline` and implements `c:deadline_changed/2`.

  Neither is forced into the other's shape: `c:deadline_changed/2` is optional, so
  a discovering scheduler simply does not implement it, and a registering one
  gets the callback it needs without every workflow paying for a table.

  ## Callbacks

  `transform/3` is the only required callback, and the only one that runs at
  compile time. It receives the resource's DSL state, every `Work` the workflow
  declared, and the options given alongside the module in the DSL, and returns
  the DSL state with whatever the implementation needs added — Oban triggers, an attribute to hold a deadline, nothing at all.
  `use AshWorkflow.Scheduler` supplies a no-op default.

  The rest are optional and run at runtime:

  * `child_spec/1` — a supervised process, for an implementation that holds
    state such as an in-memory timeline.
  * `c:deadline_changed/2` — called after a record's state changes, so a
    registering implementation can re-arm. Given the record and the work still
    ahead of it.
  * `cancel/2` — called when a record leaves a step, so a pending timer can be
    dropped. A discovering implementation needs neither.
  """

  alias AshWorkflow.Scheduler.Work

  @default AshWorkflow.Scheduler.Oban

  @doc false
  # Normalizes the `scheduler` DSL option to {module, opts}. Public only so the
  # Spark schema can reach it.
  def validate(module) when is_atom(module) and not is_nil(module), do: {:ok, {module, []}}

  def validate({module, opts}) when is_atom(module) and is_list(opts) do
    if Keyword.keyword?(opts) do
      {:ok, {module, opts}}
    else
      {:error, "expected scheduler options to be a keyword list, got: #{inspect(opts)}"}
    end
  end

  def validate(other) do
    {:error, "expected a scheduler module or a {module, options} tuple, got: #{inspect(other)}"}
  end

  @doc """
  The scheduler configured for an application, when a resource does not name one.
  """
  @spec default() :: {module(), keyword()}
  def default do
    case Application.get_env(:ash_workflow, :scheduler, @default) do
      {module, opts} -> {module, opts}
      module when is_atom(module) -> {module, []}
    end
  end

  @doc """
  Add whatever the implementation needs to the resource, at compile time.

  Called by `AshWorkflow.Transformers.AddScheduler` with every `Work` the
  workflow declares. Return the DSL state unchanged if nothing is needed.
  """
  @callback transform(dsl :: Spark.Dsl.t(), [Work.t()], opts :: keyword()) ::
              {:ok, Spark.Dsl.t()} | {:error, term()}

  @doc """
  A supervised child, for an implementation that needs a process.

  Returned to the host application to place in its own supervision tree.
  """
  @callback child_spec(opts :: keyword()) :: Supervisor.child_spec()

  @doc """
  A record's state changed, so the work ahead of it may have.

  `works` is what remains ahead of the record in its new state. A registering
  implementation re-arms from this; a discovering one does not implement it.
  """
  @callback deadline_changed(record :: Ash.Resource.record(), [Work.t()]) :: :ok

  @doc """
  Drop anything pending for this record.
  """
  @callback cancel(record :: Ash.Resource.record(), [Work.t()]) :: :ok

  @doc """
  The shortest deadline this implementation can honour, in milliseconds.

  `AshWorkflow.Verifiers.ValidateTimeoutPrecision` rejects a timeout shorter
  than this, so that the DSL cannot promise a deadline the scheduler will miss
  by more than the deadline itself. An implementation that does not define it
  is assumed to poll once a minute, which is cron's floor.
  """
  @callback precision_floor_ms(opts :: keyword()) :: pos_integer()

  @optional_callbacks child_spec: 1, deadline_changed: 2, cancel: 2, precision_floor_ms: 1

  @cron_floor_ms 60_000

  @doc """
  The shortest deadline the given scheduler can honour, in milliseconds.

  Falls back to one minute, cron's floor, for an implementation that does not
  define `c:precision_floor_ms/1`.
  """
  @spec precision_floor_ms({module(), keyword()}) :: pos_integer()
  def precision_floor_ms({module, opts}) do
    Code.ensure_loaded?(module)

    if function_exported?(module, :precision_floor_ms, 1) do
      module.precision_floor_ms(opts)
    else
      @cron_floor_ms
    end
  end

  @doc """
  Tell the resource's scheduler that a record's state changed.

  Called from `AshWorkflow.Changes.RecordEvent` after every state change. Works
  out which work now lies ahead of the record and hands it to
  `c:deadline_changed/2`, or to `c:cancel/2` when the record has reached a step
  with nothing left to schedule.

  A scheduler that discovers work by polling implements neither callback, so
  this is a no-op for it.
  """
  @spec notify_state_change(Ash.Resource.record()) :: :ok
  def notify_state_change(record) do
    resource = record.__struct__
    {module, _opts} = AshWorkflow.Info.scheduler(resource)

    Code.ensure_loaded?(module)

    works = work_ahead_of(record, resource)

    cond do
      works != [] and function_exported?(module, :deadline_changed, 2) ->
        module.deadline_changed(record, works)

      works == [] and function_exported?(module, :cancel, 2) ->
        module.cancel(record, [])

      true ->
        :ok
    end
  end

  defp work_ahead_of(record, resource) do
    state_attribute = AshStateMachine.Info.state_machine_state_attribute!(resource)

    case Map.get(record, state_attribute) do
      %Ash.NotLoaded{} ->
        []

      nil ->
        []

      state ->
        resource
        |> AshWorkflow.Info.scheduled_work()
        |> Enum.filter(&(&1.step == state))
    end
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour AshWorkflow.Scheduler

      @impl AshWorkflow.Scheduler
      def transform(dsl, _works, _opts), do: {:ok, dsl}

      defoverridable transform: 3
    end
  end

  @doc """
  Run one unit of work against one record.

  This is what an implementation calls when it decides the moment has come. It
  runs the work's action, and routes a failure to the step's `on_error` action
  when one is declared.

  Owned by AshWorkflow rather than by each implementation so that swapping the
  scheduler cannot change what a timeout does — only when it happens.
  """
  @spec execute(Work.t(), Ash.Resource.record(), keyword()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def execute(%Work{} = work, record, opts \\ []) do
    case run_action(work.action, record, opts) do
      {:ok, record} -> {:ok, record}
      {:error, error} -> handle_error(work, record, error, opts)
    end
  end

  # A change that raises rather than adding an error to the changeset is still
  # a failed step, and `on_error` is what a workflow declares for exactly that.
  # `Ash.Changeset.for_update/4` runs the action's changes while building the
  # changeset, so an exception surfaces before `Ash.update/2` is ever reached
  # and would otherwise escape past the error path.
  defp run_action(action, record, opts) do
    record
    |> Ash.Changeset.for_update(action, %{}, action_opts(opts))
    |> Ash.update(action_opts(opts))
  rescue
    error -> {:error, error}
  end

  defp handle_error(%Work{on_error: nil}, _record, error, _opts), do: {:error, error}

  defp handle_error(%Work{on_error: on_error}, record, error, opts) do
    case run_action(on_error, record, opts) do
      {:ok, record} -> {:ok, record}
      # The on_error action failing is worse than the original failure, because
      # the record is now stuck in a step nothing will retry it out of.
      {:error, on_error_error} -> {:error, {error, on_error_error}}
    end
  end

  defp action_opts(opts), do: Keyword.take(opts, [:actor, :authorize?, :tenant, :context])

  @doc """
  The instant this work becomes eligible for a record, or `nil` for work that is
  eligible as soon as the record occupies the step.

  A registering implementation arms its timer from this.
  """
  @spec due_at(Work.t(), Ash.Resource.record()) :: DateTime.t() | nil
  def due_at(%Work{deadline: nil}, _record), do: nil

  def due_at(%Work{deadline: %{field: field, after: {value, unit}}}, record) do
    case Map.get(record, field) do
      nil -> nil
      from -> DateTime.add(as_datetime(from), value, singular(unit))
    end
  end

  defp as_datetime(%DateTime{} = value), do: value
  defp as_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp singular(:days), do: :day
  defp singular(:hours), do: :hour
  defp singular(:minutes), do: :minute
  defp singular(:seconds), do: :second
end
