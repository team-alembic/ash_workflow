defmodule AshWorkflow.Entities.Timeout do
  @moduledoc """
  Defines a workflow timeout entity with its configuration schema.

  ## The `field` option

  By default, timeouts measure duration against `state_entered_at` — the timestamp
  of when the workflow entered its current state. The `field` option overrides this
  to measure against any datetime attribute or calculation on the resource.

  This enables data-driven deadlines: "3 months since their last session" rather than
  "3 months since they entered the active state."

  For a recurring action that fires on an interval for as long as a record sits
  in its step, use `AshWorkflow.Entities.Every` instead — see its moduledoc for
  why that is a separate entity rather than a `repeat` option here.
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
