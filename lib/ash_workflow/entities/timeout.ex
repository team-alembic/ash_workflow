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
    :after,
    :action,
    :transition_to,
    :check_interval,
    __spark_metadata__: nil,
    field: :state_entered_at,
    repeat: false
  ]

  @schema [
    name: [
      type: :atom,
      required: true,
      doc: "A unique name for this timeout."
    ],
    after: [
      type: {:custom, __MODULE__, :validate_duration, []},
      required: true,
      doc: "Duration tuple, e.g. `{3, :days}` or `{2, :hours}`."
    ],
    field: [
      type: :atom,
      default: :state_entered_at,
      doc:
        "The datetime attribute or calculation to measure `after` against. Defaults to `:state_entered_at`."
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
    check_interval: [
      type: :string,
      default: "* * * * *",
      doc: "Oban cron expression for how often to check this timeout. Defaults to every minute."
    ]
  ]

  def attribute_schema, do: @schema

  def validate_duration({value, unit})
      when is_integer(value) and value > 0 and unit in [:seconds, :minutes, :hours, :days] do
    {:ok, {value, unit}}
  end

  def validate_duration(other) do
    {:error, "Expected a duration tuple like {3, :days}, got: #{inspect(other)}"}
  end
end
