defmodule AshWorkflow.Calculations.Steps do
  use Ash.Resource.Calculation

  alias AshWorkflow.Resources
  alias AshWorkflow.Entities.Workflow
  alias AshWorkflow.Entities.Step

  @impl true
  def calculate(workflows, _opts, _context) do
    {:ok,
     workflows
     |> Enum.map(&calculate/1)}
  end

  def calculate(workflow) do
    workflow
    |> AshWorkflow.Info.workflow()
    |> Enum.flat_map(&steps/1)
  end

  defp steps(%Step{} = step) do
    [create_step_resource(step)]
  end

  defp steps(%Workflow{} = workflow) do
    workflow
    |> Map.get(:workflow)
    |> calculate()
  end

  defp create_step_resource(step) do
    Resources.Step
    |> Ash.Changeset.for_create(:from_step, %{step: step})
    |> Ash.create!()
  end
end
