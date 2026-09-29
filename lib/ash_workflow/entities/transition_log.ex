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

  @doc """
  Returns the actor a log row records for `actor`, or `nil` if it records none.

  It is `nil` when no actor capture is configured, when `actor` is `nil`, and
  when `skip_other_actors?` is set and `actor` is not a `destination` struct.
  """
  @spec recorded_actor(t(), term()) :: term()
  def recorded_actor(%__MODULE__{} = log, actor) do
    case belongs_to_actor(log) do
      nil ->
        nil

      %{skip_other_actors?: true, destination: destination}
      when not is_struct(actor, destination) ->
        nil

      _belongs_to_actor ->
        actor
    end
  end
end
