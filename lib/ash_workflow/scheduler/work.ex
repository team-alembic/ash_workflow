defmodule AshWorkflow.Scheduler.Work do
  @moduledoc """
  One unit of scheduled work a workflow declares, in AshWorkflow's own terms.

  This is the vocabulary a scheduler implementation is handed. It deliberately
  says nothing about Oban: no trigger, no worker, no cron. An automatic step and
  a timeout both reduce to the same shape — *run this action on the records that
  match, at or after this instant* — and the two fields that differ are what let
  opposite scheduling strategies both be correct.

  ## `match` and `deadline` are the same fact, twice

  `match` is an Ash expression selecting records eligible **now**. A scheduler
  that discovers work by asking the data layer uses this, and needs nothing
  else. It is the whole reason a polling implementation does not have to
  understand timeouts.

  `deadline` is the rule for computing the exact instant a given record becomes
  eligible. A scheduler that registers deadlines ahead of time uses this, and
  can arm a timer to the microsecond.

  A step has no `deadline` — it is eligible as soon as a record occupies it.
  A timeout has both, and they agree: `match` is true exactly when `deadline`
  has passed.

  `step` and `timeout` name where the work came from. An implementation that
  derives durable module or job names from them must keep deriving them the same
  way, since a change orphans whatever is already enqueued.

  ## Identity

  `name` is stable across compilations and unique within a resource, so a
  scheduler may use it as a durable key — a job's unique constraint, a row in
  its own table, a registry entry. Renaming a step or timeout changes it, which
  is the same breaking change it already is for the generated action names.

  ## `retry`

  `retry` is the failure policy for this work: how many attempts and how long
  between them. It is always present, defaulting to
  `%AshWorkflow.Entities.Retry{}`, one attempt and no retry, so a scheduler
  implementation can read `work.retry.max_attempts` without a nil check.
  """

  @type kind :: :step | :timeout

  @type deadline :: %{
          field: atom(),
          fire_after: {pos_integer(), AshWorkflow.Entities.Timeout.duration_unit()}
        }

  @type t :: %__MODULE__{
          name: atom(),
          kind: kind(),
          resource: Ash.Resource.t(),
          step: atom(),
          timeout: atom() | nil,
          action: atom(),
          on_error: atom() | nil,
          match: Ash.Expr.t(),
          deadline: deadline() | nil,
          repeat?: boolean(),
          repeat_until: AshWorkflow.Duration.t() | nil,
          once?: boolean(),
          self_scheduled?: boolean(),
          retry: AshWorkflow.Entities.Retry.t(),
          opts: keyword()
        }

  defstruct [
    :name,
    :kind,
    :resource,
    :step,
    :timeout,
    :action,
    :match,
    :deadline,
    on_error: nil,
    repeat?: false,
    repeat_until: nil,
    once?: false,
    self_scheduled?: false,
    retry: %AshWorkflow.Entities.Retry{},
    opts: []
  ]
end
