defmodule AshWorkflow.Transformers.AddCalculations do
  @moduledoc """
  Generates an `available_actions` calculation on the resource.

  The calculation returns the list of user-facing transition names available
  at the record's current workflow step. Only manual step transitions are
  included — automatic step actions and internal timeout actions are excluded.

  Uses `Ash.Resource.Builder.add_new_calculation/5` so that a user-defined
  `available_actions` calculation takes precedence.
  """
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  def transform(dsl) do
    steps = Transformer.get_entities(dsl, [:workflow])

    steps_map =
      steps
      |> Enum.filter(& &1.manual)
      |> Map.new(fn step ->
        {step.name, Enum.map(step.transitions, & &1.name)}
      end)

    Builder.add_new_calculation(
      dsl,
      :available_actions,
      {:array, :atom},
      {AshWorkflow.Calculations.AvailableActions, steps_map: steps_map},
      public?: true
    )
  end

  def after?(AshWorkflow.Transformers.AddCodeInterface), do: true
  def after?(_), do: false
end
