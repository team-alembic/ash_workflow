defmodule AshWorkflow.Scheduler.Precise do
  @moduledoc """
  Fires scheduled work by arming a timer for each deadline, rather than polling
  for records whose deadline has passed.

  `AshWorkflow.Scheduler.Oban` discovers work by asking the data layer which
  records match, on a cron interval, so a deadline cannot be finer than one
  minute. This scheduler is told each deadline as the record reaches it and
  arms a one-shot timer, so `fire_after: {30, :seconds}` fires 30 seconds later
  rather than up to 60 seconds after that.

  ## Selecting it

      workflow do
        scheduler AshWorkflow.Scheduler.Precise
      end

  Then start the process that holds the timers, naming the resources it sweeps:

      children = [
        {AshWorkflow.Scheduler.Precise.Timeline, resources: [MyApp.Candidate]}
      ]

  `transform/3` adds nothing to the resource. This scheduler needs no triggers,
  no workers and no attributes, which is why a workflow selecting it carries
  neither the AshOban DSL nor a deadline table.

  ## Two paths, and why both exist

  A timer lives in memory, so a node restart forgets every deadline it held.
  Precision therefore comes from one path and correctness from another.

  `c:AshWorkflow.Scheduler.deadline_changed/2` fires the moment a record enters a
  step, and arms a timer for the exact instant. That is the precise path.

  A look-ahead sweep runs every `:look_ahead_ms` and arms timers for every
  deadline falling inside the next `:horizon_ms`. That is the recovery path: it
  picks up deadlines armed by a node that has since died, deadlines set while
  this node was down, and state written by anything that did not run the
  workflow's own actions. It is the same structure a sequencer uses, where a
  loose scheduling loop places events on an exact timeline.

  Both paths converge on `AshWorkflow.Scheduler.execute/3`, and both re-read
  the record and re-check the work's `match` expression before running it, so a
  timer armed twice or armed stale does nothing the second time.

  ## Options

    * `:leader` — who decides whether this node arms timers. Defaults to
      `AshWorkflow.Scheduler.Leader.Single`. See
      `AshWorkflow.Scheduler.Leader`.
    * `:look_ahead_ms` — how often the recovery sweep runs. Defaults to 5000.
    * `:horizon_ms` — how far ahead the sweep arms timers. Defaults to 30000.
    * `:actor`, `:authorize?`, `:tenant` — passed to
      `AshWorkflow.Scheduler.execute/3`.

  ## What this gives up

  Oban's durability. A deadline held only as a timer is lost when the node
  dies, and recovered by the sweep on whichever node leads next, late by at
  most `:look_ahead_ms`. A workflow measured in days should stay on
  `AshWorkflow.Scheduler.Oban`, which is the default for that reason.
  """
  use AshWorkflow.Scheduler

  alias AshWorkflow.Scheduler.Precise.Timeline

  @impl AshWorkflow.Scheduler
  def transform(dsl, _works, _opts), do: {:ok, dsl}

  @impl AshWorkflow.Scheduler
  def precision_floor_ms(_opts), do: 1

  @impl AshWorkflow.Scheduler
  def child_spec(opts), do: Timeline.child_spec(opts)

  @impl AshWorkflow.Scheduler
  def deadline_changed(record, works), do: Timeline.deadline_changed(record, works)

  @impl AshWorkflow.Scheduler
  def cancel(record, works), do: Timeline.cancel(record, works)

  @doc """
  Run every unit of work that is due now, in the calling process.

  For tests. See `AshWorkflow.Scheduler.Precise.Timeline.run_due/2`, which this
  delegates to.

      # drive the workflow to a standstill
      Stream.repeatedly(fn -> Precise.run_due(MyApp.Candidate) end)
      |> Enum.find(&(&1 == 0))
  """
  @spec run_due(Ash.Resource.t(), keyword()) :: non_neg_integer()
  defdelegate run_due(resource, opts \\ []), to: Timeline
end
