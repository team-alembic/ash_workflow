defmodule AshWorkflow.Calculations.Steps do
  use Ash.Resource.Calculation

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
    [step]
  end

  defp steps(%Workflow{} = workflow) do
    workflow
    |> Map.get(:workflow)
    |> calculate()
  end
end
