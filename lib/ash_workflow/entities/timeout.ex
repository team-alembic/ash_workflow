defmodule AshWorkflow.Entities.Timeout do
  @moduledoc """
  Defines a workflow timeout entity with its configuration schema.

  ## The `field` option

  By default, timeouts measure duration against `state_entered_at` — the timestamp
  of when the workflow entered its current state. The `field` option overrides this
  to measure against any datetime attribute or calculation on the resource.

  This enables data-driven deadlines: "3 months since their last session" rather than
  "3 months since they entered the active state."

  ## `repeat: true` is not supported with custom fields

  Repeating timeouts work by resetting `state_entered_at` to the current time after
  each firing, which restarts the duration window. With a custom field, the extension
  would need to implicitly update that field to "now" — but this is semantically wrong.
  If `field: :last_session_date`, resetting it to "now" would claim a session happened
  when it didn't. The field's value should only change when the real-world event it
  represents actually occurs.

  Rather than silently writing incorrect data, we reject this combination at compile
  time. If you need periodic checks against a custom field, use a non-repeating timeout
  with a short `check_interval` — the trigger will keep matching on every poll cycle
  as long as the condition holds.
  """

  defstruct [
    :name,
    :fire_after,
    :action,
    :transition_to,
    :check_interval,
    self_scheduled?: false,
    __spark_metadata__: nil,
    field: :state_entered_at,
    repeat: false,
    retry: nil
  ]

  @type duration_unit :: AshWorkflow.Duration.unit()
  @type t :: %__MODULE__{
          name: atom(),
          fire_after: {pos_integer(), duration_unit()},
          action: atom() | nil,
          transition_to: atom() | nil,
          check_interval: String.t() | nil,
          self_scheduled?: boolean(),
          field: atom(),
          repeat: boolean(),
          retry: AshWorkflow.Entities.Retry.t() | nil
        }

  @schema [
    name: [
      type: :atom,
      required: true,
      doc: "A unique name for this timeout."
    ],
    fire_after: [
      type: {:custom, __MODULE__, :validate_duration, []},
      required: true,
      doc: "Duration tuple, e.g. `{3, :days}` or `{2, :hours}`."
    ],
    field: [
      type: :atom,
      default: :state_entered_at,
      doc:
        "The datetime attribute or calculation to measure `fire_after` against. Defaults to `:state_entered_at`."
    ],
    action: [
      type: :atom,
      doc: "Action to run when the timeout fires. Does not change state."
    ],
    transition_to: [
      type: :atom,
      doc: "Step to force-transition to when the timeout fires."
    ],
    repeat: [
      type: :boolean,
      default: false,
      doc: "If true, re-fire the timeout on the same interval."
    ],
    self_scheduled?: [
      type: :boolean,
      default: false,
      doc: """
      Declares that you run this timeout's trigger yourself, more often than a
      cron expression can ask for.

      Cron cannot poll more often than once a minute, so a sub-minute `fire_after`
      is normally a compile error — the deadline would fire up to 60 seconds
      late. Setting this asserts that something else drives the trigger at the
      resolution the deadline needs, and permits the shorter duration.

      This changes nothing about what is generated: the scheduler module and
      its cron are still created, so `AshOban.schedule/2` and
      `AshOban.schedule_and_run_triggers/1` keep working. It only records the
      claim, and silences the check that would otherwise reject the duration.
      """
    ],
    check_interval: [
      type: :string,
      doc: """
      Oban cron expression for how often to check this timeout, overriding the
      workflow-level `check_interval`. Defaults to the workflow's setting,
      which itself defaults to every minute.
      """
    ]
  ]

  def attribute_schema, do: @schema

  def validate_duration(value), do: AshWorkflow.Duration.validate(value)
end
