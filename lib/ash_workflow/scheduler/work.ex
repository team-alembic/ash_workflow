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

  It has two shapes, because a timeout declares its deadline in two ways.
  `%{field: :state_entered_at, fire_after: {3, :days}}` means the instant is that
  field plus that duration, which is `fire_after` in the DSL. A `fire_after` of
  `nil` means the field holds the instant itself and no arithmetic applies, which
  is `fire_at` in the DSL. `AshWorkflow.Scheduler.due_at/2` resolves both to a
  `DateTime`, so an implementation that only arms timers never has to match on
  the shape.

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

  ## `until`

  Only set for an `every` that bounds itself. `match` already folds the bound
  in — checked against `state_entered_at`, not against `deadline`'s own
  `field` — so an implementation that reads `match` needs nothing else.
  `until` is exposed on `Work` for one that wants to filter ahead of a full
  match evaluation, the way `AshWorkflow.Scheduler.Precise.Timeline`'s
  recovery sweep does.

  ## `fired_field`

  Only set for an action timeout. An action timeout does not change state, so
  without a record of its firing it would match again on the next poll. The
  column this names, `<step>_<timeout>_fired_at`, is that record:
  `AshWorkflow.Changes.RecordEvent` writes it when the action runs, and `match`
  folds in `not_fired/1`. Like `until`, it is exposed for an implementation
  that filters ahead of a full match evaluation.
  """

  import Ash.Expr, only: [ref: 1]
  require Ash.Expr

  @type kind :: :step | :timeout

  @type deadline :: %{
          field: atom(),
          fire_after: {pos_integer(), AshWorkflow.Entities.Timeout.duration_unit()} | nil
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
          until: AshWorkflow.Duration.t() | nil,
          fired_field: atom() | nil,
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
    until: nil,
    fired_field: nil,
    self_scheduled?: false,
    retry: %AshWorkflow.Entities.Retry{},
    opts: []
  ]

  @doc """
  The expression that is true while this work has not fired for the deadline
  the record holds now.

  Compared against the deadline, not the moment the record entered the step.
  A new visit moves a `state_entered_at` deadline later, and a timeout action
  that advances its own `fire_at` field moves that deadline later, so either
  makes the timeout due again. Two timeouts on one step that share an action
  both have their column written when it runs, and the later deadline still
  fires because its column holds an instant before it.

  Always true for work with no `fired_field`.
  """
  @spec not_fired(t()) :: Ash.Expr.t()
  def not_fired(%__MODULE__{fired_field: nil}), do: true

  def not_fired(%__MODULE__{fired_field: fired_field, deadline: deadline}) do
    Ash.Expr.expr(is_nil(^ref(fired_field)) or ^ref(fired_field) < ^deadline_expr(deadline))
  end

  defp deadline_expr(%{field: field, fire_after: nil}), do: ref(field)

  # `datetime_add/3` returns `:utc_datetime`, which truncates to whole seconds
  # when Ash evaluates it in memory. A firing in the same second as its
  # deadline would then read as before it. Adding a `Duration` keeps the
  # microseconds.
  defp deadline_expr(%{field: field, fire_after: {value, unit}}) do
    Ash.Expr.expr(^ref(field) + ^Duration.new!([{singular(unit), value}]))
  end

  defp singular(:days), do: :day
  defp singular(:hours), do: :hour
  defp singular(:minutes), do: :minute
  defp singular(:seconds), do: :second
end
