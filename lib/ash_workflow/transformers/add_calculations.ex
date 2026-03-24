defmodule AshWorkflow.Transformers.AddCalculations do
  @moduledoc """
  Generates workflow calculations on the resource.

  Adds the following calculations (using `add_new_calculation` so user-defined
  calculations take precedence):

  - `:available_actions` — list of user-facing transition names for the current step
  - `:steps` — list of all workflow step names (static, same for every record)
  - `:current_step` — the name of the workflow's current step
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

    step_names = Enum.map(steps, & &1.name)

    with {:ok, dsl} <-
           Builder.add_new_calculation(
             dsl,
             :available_actions,
             {:array, :atom},
             {AshWorkflow.Calculations.AvailableActions, steps_map: steps_map},
             public?: true
           ),
         {:ok, dsl} <-
           Builder.add_new_calculation(
             dsl,
             :steps,
             {:array, :atom},
             {AshWorkflow.Calculations.Steps, step_names: step_names},
             public?: true
           ) do
      Builder.add_new_calculation(
        dsl,
        :current_step,
        :atom,
        AshWorkflow.Calculations.CurrentStep,
        public?: true
      )
    end
  end

  def after?(AshWorkflow.Transformers.AddCodeInterface), do: true
  def after?(_), do: false
end
