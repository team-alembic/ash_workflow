defmodule AshWorkflow.Calculations.Steps do
  use Ash.Resource.Calculation

  alias AshWorkflow.Dsl.{ActionStep, WorkflowStep, Switch}

  import AshWorkflow.Calculations.Helper

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

  defp steps(%ActionStep{} = step) do
    [create_step(step)]
  end

  defp steps(%WorkflowStep{} = workflow) do
    workflow
    |> Map.get(:workflow)
    |> calculate()
  end

  defp steps(%Switch{} = switch) do
    switch.matches
    |> Enum.map(& &1.step)
    |> Enum.concat(List.wrap(switch.default.step))
  end
end
