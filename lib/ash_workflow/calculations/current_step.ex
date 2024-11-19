defmodule AshWorkflow.Calculations.CurrentStep do
  use Ash.Resource.Calculation

  alias AshWorkflow.Dsl.Switch
  alias AshWorkflow.Dsl.{ActionStep, WorkflowStep}

  import AshWorkflow.Calculations.Helper
  import AshWorkflow.Helper

  @impl true
  def load(_, _, _), do: []

  @impl true
  def calculate(workflows, _opts, context) do
    opts = Ash.Context.to_opts(context)

    {:ok,
     workflows
     |> Enum.map(&current_step(&1, opts))}
  end

  def current_step(workflow, opts) do
    current_step(AshWorkflow.Info.step(workflow, workflow.state), workflow, opts)
  end

  defp current_step(nil, _workflow, _opts), do: nil

  defp current_step(%ActionStep{} = step, _workflow, opts) do
    create_step(step, opts)
  end

  defp current_step(%WorkflowStep{workflow: workflow_module, name: name}, workflow, opts) do
    workflow = sub_workflow(workflow, name, workflow_module, opts)
    current_step(workflow, opts)
  end

  defp current_step(%Switch{} = step, workflow, opts) do
    step = step_from_switch(step, workflow)
    current_step(step, workflow, opts)
  end
end
