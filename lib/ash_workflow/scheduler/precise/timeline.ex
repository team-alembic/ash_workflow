defmodule AshWorkflow.Scheduler.Precise.Timeline do
  @moduledoc """
  Holds the armed deadlines for `AshWorkflow.Scheduler.Precise`.

  One timer per pending deadline, keyed by resource, work name and primary key.
  A record entering a step replaces every timer it already had, and a record
  reaching a terminal step drops them.

  ## Start it with the resources it sweeps

      {AshWorkflow.Scheduler.Precise.Timeline, resources: [MyApp.Candidate]}

  The DSL selects a scheduler per resource, but this process is started once by
  the application, so it cannot infer which resources to recover deadlines for.
  Listing them is what makes the sweep possible. A resource whose workflow
  selects a different scheduler is ignored, so listing one is harmless.

  ## Firing

  Every fire re-reads the record and re-applies the work's `match` expression
  before running the action. That check is what makes a duplicate timer safe,
  and it is the same guarantee ash_oban gets by re-checking a trigger's `where`
  before a job runs. A record that has left the step, or had its deadline
  moved, fires nothing.

  ## Retry

  A failed attempt that has not yet reached `work.retry.max_attempts` re-arms a
  timer for the backoff delay, under the same key as the original deadline.
  That is what lets a record leaving the step drop a pending retry through the
  same `drop_timers_for/2` and `cancel/2` paths as any other timer. `on_error`
  only runs once the last attempt has failed, exactly as
  `AshWorkflow.Scheduler.execute/3` decides.
  """
  use GenServer

  require Logger

  alias AshWorkflow.Info
  alias AshWorkflow.Scheduler
  alias AshWorkflow.Scheduler.Leader
  alias AshWorkflow.Scheduler.Work

  import Ash.Expr, only: [ref: 1]
  require Ash.Expr

  @default_look_ahead_ms 5_000
  @default_horizon_ms 30_000

  defstruct [
    :leader,
    :look_ahead_ms,
    :horizon_ms,
    :action_opts,
    resources: [],
    timers: %{}
  ]

  @doc """
  Start the timeline.

  ## Options

    * `:resources` — the workflow resources to sweep for pending deadlines.
    * `:name` — the process name. Defaults to this module.
    * `:leader`, `:look_ahead_ms`, `:horizon_ms`, `:actor`, `:authorize?`,
      `:tenant` — see `AshWorkflow.Scheduler.Precise`.
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Replace every timer this record has with the deadlines of its current state.

  Called by `AshWorkflow.Scheduler.notify_state_change/1` after a state change.
  Replacing rather than adding is what stops a record that moved between steps
  from keeping the previous step's deadlines armed.
  """
  @spec deadline_changed(Ash.Resource.record(), [Work.t()]) :: :ok
  def deadline_changed(record, works, name \\ __MODULE__) do
    GenServer.cast(name, {:rearm, record, works})
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Drop every timer this record has.
  """
  @spec cancel(Ash.Resource.record(), [Work.t()]) :: :ok
  def cancel(record, _works, name \\ __MODULE__) do
    GenServer.cast(name, {:drop, record})
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Run every unit of work that is due now for a resource, in the calling process.

  This is the synchronous counterpart to the timers, and it exists for tests.
  A timer fires from this process, which under `Ecto.Adapters.SQL.Sandbox`
  cannot see the test's transaction, so a test that waited for a timer would
  wait for work that could not read its own data. Calling this instead runs the
  same work through `AshWorkflow.Scheduler.execute/3` on the test's own
  connection.

  `Work.match` is what "due now" means: for a timeout it is true exactly when
  the deadline has passed, and for an automatic step it is true as soon as a
  record occupies it. So this needs no horizon and no timer.

  Returns the number of records it ran work for. An automatic step that
  transitions into another automatic step needs another call, the same way
  `AshOban.schedule_and_run_triggers/1` needs another pass, so loop until it
  returns 0.

      run_due(MyApp.Candidate)
      #=> 2
  """
  @spec run_due(Ash.Resource.t(), keyword()) :: non_neg_integer()
  def run_due(resource, opts \\ []) do
    state = %__MODULE__{action_opts: Keyword.take(opts, [:actor, :authorize?, :tenant])}

    resource
    |> Info.scheduled_work()
    |> Enum.reduce(0, fn work, count ->
      records =
        work.resource
        |> read(recheck_filter(work), state, deadline_loads(work))
        |> Enum.filter(&due_now?(work, &1))

      Enum.each(records, &run_once(work, &1, state))

      count + length(records)
    end)
  end

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      resources: Keyword.get(opts, :resources, []),
      leader: Leader.normalize(opts[:leader]),
      look_ahead_ms: Keyword.get(opts, :look_ahead_ms, @default_look_ahead_ms),
      horizon_ms: Keyword.get(opts, :horizon_ms, @default_horizon_ms),
      action_opts: Keyword.take(opts, [:actor, :authorize?, :tenant])
    }

    warn_if_clustered_without_election(state)

    {:ok, state, {:continue, :sweep}}
  end

  @impl GenServer
  def handle_continue(:sweep, state), do: handle_info(:sweep, state)

  @impl GenServer
  def handle_info(:sweep, state) do
    state =
      if Leader.leader?(state.leader) do
        Enum.reduce(state.resources, state, &sweep_resource(&2, &1))
      else
        drop_all_timers(state)
      end

    {:noreply, schedule_sweep(state)}
  end

  def handle_info({:fire, key, work, attempt}, state) do
    state = %{state | timers: Map.delete(state.timers, key)}

    state =
      if Leader.leader?(state.leader) do
        {_resource, _name, primary_key} = key
        fire(work, primary_key, attempt, state)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_cast({:rearm, record, works}, state) do
    state = drop_timers_for(state, record)

    state =
      if Leader.leader?(state.leader) do
        Enum.reduce(works, state, &arm(&2, &1, record))
      else
        state
      end

    {:noreply, state}
  end

  def handle_cast({:drop, record}, state) do
    {:noreply, drop_timers_for(state, record)}
  end

  @impl GenServer
  def terminate(_reason, state) do
    drop_all_timers(state)

    :ok
  end

  # Sweeping

  defp sweep_resource(state, resource) do
    if precise?(resource) do
      resource
      |> Info.scheduled_work()
      |> Enum.reduce(state, &sweep_work(&2, &1))
    else
      state
    end
  end

  # A resource may be listed in `:resources` while its workflow selects another
  # scheduler. Sweeping it would run work the selected scheduler is also
  # running, so skip it rather than double-fire.
  defp precise?(resource) do
    match?({AshWorkflow.Scheduler.Precise, _opts}, Info.scheduler(resource))
  end

  defp sweep_work(state, %Work{deadline: nil} = work) do
    # An automatic step is eligible as soon as a record occupies it, so there
    # is no instant to arm a timer for. Run the matching records now.
    work
    |> due_records(state, nil)
    |> Enum.reduce(state, &run(work, &1, 1, &2))
  end

  defp sweep_work(state, %Work{} = work) do
    cutoff = DateTime.add(DateTime.utc_now(), state.horizon_ms, :millisecond)

    work
    |> due_records(state, cutoff)
    |> Enum.reduce(state, &arm(&2, work, &1))
  end

  # For a deadline of `field + fire_after`, a record's deadline falls inside the
  # horizon when `field <= cutoff - fire_after`. Computing the bound in Elixir keeps
  # it a bind parameter, so the query is the same indexed range scan the polled
  # scheduler gets.
  defp due_records(%Work{deadline: nil} = work, state, _cutoff) do
    read(work.resource, work.match, state)
  end

  # A wall-clock `every`'s occurrence depends on the zone in the row, so there
  # is no bound to fold into the filter the way `fire_after` arithmetic folds
  # in. Read the records in the step and let `arm/3` compute each occurrence
  # through `AshWorkflow.Scheduler.due_at/2`.
  defp due_records(%Work{deadline: %{wall_clock: _schedule}} = work, state, _cutoff) do
    filter = until_filter(Ash.Expr.expr(^in_step(work)), work)

    read(work.resource, filter, state, deadline_loads(work))
  end

  defp due_records(%Work{deadline: %{field: field, fire_after: fire_after}} = work, state, cutoff) do
    bound = bound(cutoff, fire_after)

    filter =
      Ash.Expr.expr(^in_step(work) and ^field_due(work, field, bound))
      |> until_filter(work)

    read(work.resource, filter, state, deadline_loads(work))
  end

  # `Work.match` already reads the attribute the workflow named, and this filter
  # is rebuilt rather than reused so the horizon's bound can be folded in, so it
  # has to read the same attribute rather than assume `state`.
  defp in_step(%Work{resource: resource, step: step}) do
    Ash.Expr.expr(^ref(Info.state_attribute(resource)) == ^step)
  end

  # A repeating `every` whose column is still `nil` has never fired, so its
  # interval is measured from `state_entered_at` instead. See
  # `AshWorkflow.Entities.Every`. A plain timeout's field has no such case: it
  # either measures `state_entered_at`, which always has a value, or a
  # data-driven field the record's own logic is responsible for populating.
  defp field_due(%Work{repeat?: true}, field, bound) do
    Ash.Expr.expr(
      (is_nil(^ref(field)) and ^ref(:state_entered_at) <= ^bound) or ^ref(field) <= ^bound
    )
  end

  defp field_due(%Work{repeat?: false}, field, bound) do
    Ash.Expr.expr(^ref(field) <= ^bound)
  end

  # A `fire_at` deadline is the field itself, so the horizon's cutoff is already
  # the bound to compare it against. Either way the bound is computed in Elixir
  # and reaches the data layer as a bind parameter.
  defp bound(cutoff, nil), do: cutoff
  defp bound(cutoff, {value, unit}), do: DateTime.add(cutoff, -value, singular(unit))

  # `AshWorkflow.Scheduler.due_at/2` reads the deadline field off the record with
  # `Map.get/2`, which finds nothing for a calculation that has not been loaded.
  # A timeout may name an expression calculation as its `field` or its `fire_at`,
  # so load it with the records the timer is armed from.
  defp deadline_loads(%Work{deadline: %{} = deadline, resource: resource}) do
    [deadline.field | time_zone_field(deadline)]
    |> Enum.filter(&Ash.Resource.Info.calculation(resource, &1))
  end

  defp deadline_loads(%Work{}), do: []

  # A wall-clock `every` whose `time_zone` names a calculation — reading the
  # zone off a related record, say — cannot compute an occurrence without it,
  # and `AshWorkflow.Scheduler.due_at/2` reads it off the record with
  # `Map.get/2`, which finds nothing for a calculation nobody loaded.
  defp time_zone_field(%{wall_clock: %AshWorkflow.WallClock{time_zone: zone}})
       when is_atom(zone) and not is_nil(zone),
       do: [zone]

  defp time_zone_field(_deadline), do: []

  # Without this, a record whose `until` bound has already passed keeps
  # matching the plain `field <= bound` filter above forever, so every sweep
  # arms a timer for it, `fire/4` re-checks `Work.match` and finds nothing, and
  # the cycle repeats every `look_ahead_ms`. Filtering it out here means a
  # bound-exceeded record stops costing a query once it stops being eligible,
  # the same way it already stops matching `AshWorkflow.Scheduler.Oban`'s
  # trigger `where`. Checked against "now" rather than `cutoff`, unlike the
  # `fire_after` bound above: this excludes only a record that is *already*
  # bound-exceeded, not one that merely will be by the time the horizon closes.
  defp until_filter(filter, %Work{until: nil}), do: filter

  defp until_filter(filter, %Work{until: {value, unit}}) do
    bound = DateTime.add(DateTime.utc_now(), -value, singular(unit))

    Ash.Expr.expr(^filter and ^ref(:state_entered_at) > ^bound)
  end

  defp read(resource, filter, state, loads \\ []) do
    opts =
      state.action_opts
      |> Keyword.put_new(:authorize?, false)
      # AshWorkflow's generated read action paginates by default, so a plain
      # read returns one page of due records rather than all of them. It sets
      # `required?: false` precisely so this can opt out.
      |> Keyword.put(:page, false)

    resource
    |> Ash.Query.new()
    |> Ash.Query.do_filter(filter)
    |> Ash.Query.load(loads)
    |> Ash.read(opts)
    |> case do
      {:ok, records} when is_list(records) ->
        records

      # A resource whose own read action requires pagination hands back a page
      # instead. Its records are still the due ones; a backlog larger than the
      # page waits for the next sweep.
      {:ok, %{results: records}} ->
        records

      {:error, error} ->
        warn_unreadable(resource, error)

        []
    end
  rescue
    # This process holds every armed timer, so a read that raises must not take
    # it down. A data layer with no connection available raises rather than
    # returning an error tuple, and losing one sweep costs a deadline at most
    # `:look_ahead_ms` of lateness. Losing the process costs every deadline it
    # was holding.
    error ->
      warn_unreadable(resource, error)

      []
  end

  defp warn_unreadable(resource, error) do
    Logger.warning("""
    #{inspect(__MODULE__)} could not read #{inspect(resource)} while looking for \
    due deadlines: #{Exception.message(error)}
    """)
  end

  # Arming

  defp arm(state, %Work{} = work, record) do
    case delay_ms(work, record) do
      nil ->
        state

      delay when delay <= 0 ->
        # Through `fire/4` rather than straight to `run/4`, so this path
        # re-checks `Work.match` exactly as an expired timer does. A record
        # handed to `deadline_changed/2` is whatever the caller held, and a
        # deadline already in the past would otherwise run its action without
        # anything confirming the record still occupies the step.
        fire(work, primary_key(record), 1, state)

      delay ->
        key = key(work, record)
        state = cancel_timer(state, key)
        # A one-shot timer accumulates no drift, so a computed delay is as
        # accurate here as an absolute monotonic target would be.
        timer = Process.send_after(self(), {:fire, key, work, 1}, delay)

        %{state | timers: Map.put(state.timers, key, timer)}
    end
  end

  # An automatic step has no deadline and is eligible the moment a record
  # occupies it, so it runs now. A timeout whose field is nil on this record
  # has no deadline yet — `due_at/2` cannot compute one — and arming nothing is
  # correct until the field is written. A repeating `every`'s column is the one
  # field that is nil by design until its first fire — see
  # `AshWorkflow.Entities.Every` — so the delay is computed from
  # `state_entered_at` instead, putting the first firing one whole interval
  # after entry. `AshWorkflow.Scheduler.due_at/2` stays unaware of this
  # substitution; it belongs to the scheduler, not the shared deadline
  # arithmetic.
  defp delay_ms(%Work{deadline: nil}, _record), do: 0

  defp delay_ms(%Work{deadline: %{field: field}, repeat?: true} = work, record) do
    case Map.get(record, field) do
      nil -> due_delay(work, Map.put(record, field, record.state_entered_at))
      _fired_at -> due_delay(work, record)
    end
  end

  defp delay_ms(work, record), do: due_delay(work, record)

  defp due_delay(work, record) do
    case Scheduler.due_at(work, record) do
      nil ->
        nil

      due_at ->
        due_at
        |> DateTime.diff(DateTime.utc_now(), :microsecond)
        |> to_timer_ms()
    end
  end

  # A timer must never fire before its deadline. `Work.match` re-checks the
  # deadline in SQL at fire time, so a timer that runs even a fraction of a
  # millisecond early reads its own deadline as not yet passed, fires nothing,
  # and leaves the deadline to the next sweep. `DateTime.diff/3` truncates
  # toward zero, which is exactly that error, so round up and add a
  # millisecond. A deadline means "at or after this instant", so arriving a
  # millisecond late is correct and arriving early is not.
  defp to_timer_ms(microseconds) when microseconds <= 0, do: 0
  defp to_timer_ms(microseconds), do: div(microseconds + 999, 1_000) + 1

  defp key(%Work{} = work, record) do
    {work.resource, work.name, primary_key(record)}
  end

  defp primary_key(record) do
    record
    |> Ash.Resource.Info.primary_key()
    |> Enum.map(&Map.fetch!(record, &1))
  end

  # Firing

  defp fire(%Work{} = work, primary_key, attempt, state) do
    pk_filter =
      work.resource
      |> Ash.Resource.Info.primary_key()
      |> Enum.zip(primary_key)

    filter = Ash.Expr.expr(^Ash.Expr.expr(^pk_filter) and ^recheck_filter(work))

    case read(work.resource, filter, state, deadline_loads(work)) do
      # The record left the step, or its deadline moved. Whatever armed this
      # timer is out of date, and doing nothing is the correct outcome.
      [] -> state
      [record] -> if due_now?(work, record), do: run(work, record, attempt, state), else: state
    end
  end

  # `Work.match` for a wall-clock `every` is a SQL fragment, because the polled
  # scheduler has to ask the data layer to read the zone out of each row. This
  # scheduler computes the same occurrence in Elixir through
  # `AshWorkflow.WallClock`, so it re-checks the step and the `until` bound in
  # the data layer and the occurrence itself in `due_now?/2`. That keeps
  # `AshWorkflow.Scheduler.Precise` working on a data layer with no `fragment`
  # support at all.
  defp recheck_filter(%Work{deadline: %{wall_clock: _schedule}} = work) do
    until_filter(Ash.Expr.expr(^in_step(work)), work)
  end

  defp recheck_filter(%Work{match: match}), do: match

  defp due_now?(%Work{deadline: %{wall_clock: _schedule}} = work, record) do
    case Scheduler.due_at(work, record) do
      nil -> false
      due_at -> not DateTime.after?(due_at, DateTime.utc_now())
    end
  end

  defp due_now?(%Work{}, _record), do: true

  defp run(%Work{} = work, record, attempt, state) do
    action_opts = Keyword.put(state.action_opts, :attempt, attempt)

    case Scheduler.execute(work, record, action_opts) do
      {:ok, _record} ->
        state

      {:retry, delay_ms} ->
        arm_retry(state, work, record, attempt, delay_ms)

      {:error, error} ->
        warn_failed(work, error)
        state
    end
  end

  # Rearms under the same key the original deadline used, so a record leaving
  # the step drops a pending retry through the same `drop_timers_for/2` and
  # `cancel/2` paths as any other timer.
  defp arm_retry(state, work, record, attempt, delay_ms) do
    key = key(work, record)
    state = cancel_timer(state, key)
    timer = Process.send_after(self(), {:fire, key, work, attempt + 1}, delay_ms)

    %{state | timers: Map.put(state.timers, key, timer)}
  end

  # A retry needs the timer-holding process to re-arm, which `run_due/2` does
  # not have — it runs synchronously in the caller's process, for tests. So it
  # runs attempt 1 only and treats a requested retry as nothing left to do.
  defp run_once(work, record, state) do
    case Scheduler.execute(work, record, Keyword.put(state.action_opts, :attempt, 1)) do
      {:ok, _record} -> :ok
      {:retry, _delay_ms} -> :ok
      {:error, error} -> warn_failed(work, error)
    end
  end

  defp warn_failed(work, error) do
    Logger.warning("""
    #{inspect(__MODULE__)} failed to run #{inspect(work.name)} on \
    #{inspect(work.resource)}: #{inspect(error)}
    """)
  end

  # Timers

  defp schedule_sweep(state) do
    Process.send_after(self(), :sweep, state.look_ahead_ms)

    state
  end

  defp cancel_timer(state, key) do
    case Map.fetch(state.timers, key) do
      {:ok, timer} ->
        Process.cancel_timer(timer)

        %{state | timers: Map.delete(state.timers, key)}

      :error ->
        state
    end
  end

  defp drop_timers_for(state, record) do
    primary_key = primary_key(record)
    resource = record.__struct__

    state.timers
    |> Map.keys()
    |> Enum.filter(&match?({^resource, _name, ^primary_key}, &1))
    |> Enum.reduce(state, &cancel_timer(&2, &1))
  end

  defp drop_all_timers(state) do
    state.timers
    |> Map.keys()
    |> Enum.reduce(state, &cancel_timer(&2, &1))
  end

  defp warn_if_clustered_without_election(%{leader: {Leader.Single, _opts}}) do
    case Node.list() do
      [] ->
        :ok

      nodes ->
        Logger.warning("""
        #{inspect(__MODULE__)} is running on #{inspect(Leader.Single)}, which makes \
        every node the leader, and #{length(nodes)} other node(s) are connected: \
        #{inspect(nodes)}. Each of them will arm the same timers, so every deadline \
        fires once per node.

        Elect one node instead:

            {#{inspect(__MODULE__)},
             resources: [...],
             leader: {#{inspect(Leader.Oban)}, name: Oban}}
        """)
    end
  end

  defp warn_if_clustered_without_election(_state), do: :ok

  defp singular(:days), do: :day
  defp singular(:hours), do: :hour
  defp singular(:minutes), do: :minute
  defp singular(:seconds), do: :second
end
