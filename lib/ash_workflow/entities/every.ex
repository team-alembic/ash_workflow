defmodule AshWorkflow.Entities.Every do
  @moduledoc """
  Defines a recurring action entity with its configuration schema.

  `every` is not a timeout: nothing is timing out. It is a recurring action
  that runs on an interval for as long as a record sits in its step. Firing
  never leaves the step — there is no `transition_to` — so `every` always
  requires an `action`.

  ## Why there is no `field` option

  `AshWorkflow.Entities.Timeout` lets `fire_after` measure against a custom
  datetime field instead of `state_entered_at`. `every` does not offer that,
  because a recurring action works by resetting `state_entered_at` to the
  current time after each firing, which restarts the interval. With a custom
  field, the extension would need to implicitly update that field to "now" —
  but that is semantically wrong. If the field were `:last_session_date`,
  resetting it to "now" would claim a session happened when it didn't. The
  field's value should only change when the real-world event it represents
  actually occurs.

  Rather than silently writing incorrect data, `every` always measures against
  `state_entered_at`. If you need a periodic check against a custom field, use
  a non-repeating `timeout` with a short `check_interval` — its trigger keeps
  matching on every poll cycle as long as the condition holds.

  ## Bounding an `every` with `until`

  `every` alone fires forever. `until` stops it after a fixed amount of
  wall-clock time:

      every :reminder do
        interval {2, :days}
        action :send_review_reminder
        until {8, :days}
      end

  `until` cannot be measured against `state_entered_at`, the same attribute
  `interval` measures against, because firing is what keeps resetting it — a
  bound checked against it would never be reached. It is measured against
  `repeat_started_at` instead, an attribute `AshWorkflow.Transformers.AddAttributes`
  adds when some `every` declares `until`. Every genuine step entry writes it
  alongside `state_entered_at`; no `every` firing touches it. See
  `AshWorkflow.Changes.RecordEvent`'s `:repeat_fire?` option for how that
  distinction is made, and `AshWorkflow.Verifiers.ValidateEvery` for why
  `until` must be strictly longer than `interval`.

  Reaching the bound only stops the firing. It does not transition state —
  compose a second, ordinary timeout with a `fire_after` equal to the bound
  for "give up and move on".
  """

  defstruct [
    :name,
    :interval,
    :action,
    :until,
    :check_interval,
    self_scheduled?: false,
    __spark_metadata__: nil,
    retry: nil
  ]

  @type duration_unit :: AshWorkflow.Duration.unit()
  @type t :: %__MODULE__{
          name: atom(),
          interval: {pos_integer(), duration_unit()},
          action: atom(),
          until: AshWorkflow.Duration.t() | nil,
          check_interval: String.t() | nil,
          self_scheduled?: boolean(),
          retry: AshWorkflow.Entities.Retry.t() | nil
        }

  @schema [
    name: [
      type: :atom,
      required: true,
      doc: "A unique name for this recurring action."
    ],
    interval: [
      type: {:custom, __MODULE__, :validate_duration, []},
      required: true,
      doc: "Duration tuple, e.g. `{1, :day}` or `{2, :hours}`."
    ],
    action: [
      type: :atom,
      required: true,
      doc: "Action to run each time the interval elapses. Does not change state."
    ],
    until: [
      type: {:custom, AshWorkflow.Duration, :validate, []},
      doc: """
      Stop firing once this much wall-clock time has passed since the record
      entered the step.

      Measured against `repeat_started_at`, never against `state_entered_at`,
      which every firing resets. Must be strictly longer than `interval`,
      since equal to it leaves no room to fire even once.
      """
    ],
    self_scheduled?: [
      type: :boolean,
      default: false,
      doc: """
      Declares that you run this action's trigger yourself, more often than a
      cron expression can ask for.

      Cron cannot poll more often than once a minute, so a sub-minute
      `interval` is normally a compile error — the action would fire up to 60
      seconds late. Setting this asserts that something else drives the
      trigger at the resolution the interval needs, and permits the shorter
      duration.

      This changes nothing about what is generated: the scheduler module and
      its cron are still created, so `AshOban.schedule/2` and
      `AshOban.schedule_and_run_triggers/1` keep working. It only records the
      claim, and silences the check that would otherwise reject the duration.
      """
    ],
    check_interval: [
      type: :string,
      doc: """
      Oban cron expression for how often to check this action, overriding the
      workflow-level `check_interval`. Defaults to the workflow's setting,
      which itself defaults to every minute.
      """
    ]
  ]

  def attribute_schema, do: @schema

  def validate_duration(value), do: AshWorkflow.Duration.validate(value)

  @doc """
  The attribute `until` is measured against.
  """
  @spec until_anchor() :: atom()
  def until_anchor, do: :repeat_started_at
end
