defmodule AshWorkflow.Entities.Undo do
  @moduledoc """
  Configures undo for a workflow.

  Undo rewinds a record to the state it occupied before its most recent state
  change, and records that rewind as a *new* transition log row whose
  `undoes_id` points at the row it reverses. The log is never mutated: history
  stays append-only, and both readings of it remain derivable — what actually
  happened, and what stands after corrections.

      undo do
        within {30, :minutes}
        same_actor? true
      end

  Undo is opt-in twice over. The `undo` block enables the feature, and each
  transition that may be rewound must be marked `undoable?: true`. A workflow
  with an `undo` block but no undoable transitions is rejected at compile time.

  Requires a `transition_log` — there is nothing to rewind to without one.
  """

  defstruct [:within, :policy, __spark_metadata__: nil, same_actor?: false]

  @type t :: %__MODULE__{
          within: {pos_integer(), AshWorkflow.Entities.Timeout.duration_unit()} | nil,
          same_actor?: boolean(),
          policy: term() | nil
        }

  @schema [
    within: [
      type: {:custom, AshWorkflow.Entities.Timeout, :validate_duration, []},
      doc: """
      How long after a transition it may still be undone, e.g. `{30, :minutes}`.

      Measured against the undone row's `occurred_at`. Defaults to `nil`, which
      places no time limit on undo.
      """
    ],
    same_actor?: [
      type: :boolean,
      default: false,
      doc: """
      If true, only the actor recorded on a transition may undo it.

      Requires `belongs_to_actor` on the `transition_log` — without a recorded
      actor there is nothing to compare against, so this is rejected at compile
      time.
      """
    ],
    policy: [
      type: :any,
      doc: """
      An Ash policy check applied to the generated `undo` action. Accepts any
      `{module, opts}` tuple implementing `Ash.Policy.Check`.

      Step policies do not apply to undo: an undo spans two states, and which
      step it rewinds into is only known at runtime. Without this option the
      `undo` action falls under the extension's default-allow policy, like
      every other generated action.
      """
    ]
  ]

  def attribute_schema, do: @schema

  @doc """
  Returns `within` as a count of seconds, or `nil` when no window is configured.
  """
  @spec window_seconds(t()) :: pos_integer() | nil
  def window_seconds(%__MODULE__{within: nil}), do: nil
  def window_seconds(%__MODULE__{within: {value, unit}}), do: value * unit_seconds(unit)

  defp unit_seconds(:seconds), do: 1
  defp unit_seconds(:minutes), do: 60
  defp unit_seconds(:hours), do: 3600
  defp unit_seconds(:days), do: 86_400
end
