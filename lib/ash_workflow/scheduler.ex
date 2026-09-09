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
  cron. It reads `Work.match` and ignores `deadline_changed/2`.

  A **registering** scheduler is told each deadline as it becomes known and arms
  a timer for it. Its floor is the timer, which is microseconds. It reads
  `Work.deadline` and implements `deadline_changed/2`.

  Neither is forced into the other's shape: `deadline_changed/2` is optional, so
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
  * `deadline_changed/2` — called after a record's state changes, so a
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

  @optional_callbacks child_spec: 1, deadline_changed: 2, cancel: 2

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
    record
    |> Ash.Changeset.for_update(work.action, %{}, action_opts(opts))
    |> Ash.update(action_opts(opts))
    |> case do
      {:ok, record} -> {:ok, record}
      {:error, error} -> handle_error(work, record, error, opts)
    end
  end

  defp handle_error(%Work{on_error: nil}, _record, error, _opts), do: {:error, error}

  defp handle_error(%Work{on_error: on_error}, record, error, opts) do
    record
    |> Ash.Changeset.for_update(on_error, %{}, action_opts(opts))
    |> Ash.update(action_opts(opts))
    |> case do
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
