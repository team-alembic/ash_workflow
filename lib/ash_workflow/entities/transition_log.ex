defmodule AshWorkflow.Entities.TransitionLog do
  @moduledoc """
  Configures an opt-in transition log for a workflow.

  When present, `AshWorkflow.Changes.RecordEvent` appends one row per workflow
  event to `resource`, and the resource gains the `state_at/2` and `history/1`
  code interface functions and a public `has_many :transitions` relationship to
  `resource`. A `:transitions` relationship defined on the workflow resource
  takes precedence.

  The log resource itself is user-owned, not generated — see
  `AshWorkflow.Verifiers.ValidateTransitionLog` for the schema it must satisfy.
  """

  defstruct [:resource, __spark_metadata__: nil, belongs_to_actor: []]

  @type t :: %__MODULE__{
          resource: module(),
          belongs_to_actor: [AshWorkflow.Entities.BelongsToActor.t()]
        }

  @schema [
    resource: [
      type: :atom,
      required: true,
      doc: """
      The transition log resource module. Scaffolded with
      `mix ash_workflow.gen.transition_log` and validated at compile time by
      `AshWorkflow.Verifiers.ValidateTransitionLog`.
      """
    ]
  ]

  def attribute_schema, do: @schema

  @doc "Returns the configured actor capture, or `nil` if none is configured."
  @spec belongs_to_actor(t()) :: AshWorkflow.Entities.BelongsToActor.t() | nil
  def belongs_to_actor(%__MODULE__{belongs_to_actor: [actor | _]}), do: actor
  def belongs_to_actor(%__MODULE__{}), do: nil
end
