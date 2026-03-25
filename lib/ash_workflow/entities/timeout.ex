defmodule AshWorkflow.Entities.Timeout do
  @moduledoc "Defines a workflow timeout entity with its configuration schema."

  defstruct [:name, :after, :action, :transition_to, :check_interval, :field, repeat: false]

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
