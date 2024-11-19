defmodule AshWorkflowTest do
  alias AshWorkflowTest.Step1
  use ExUnit.Case
  doctest AshWorkflow

  test "greets the world" do
    {:ok, workflow} = AshWorkflowTest.Workflow.start()

    assert workflow.state == :create_step1_resource

    {:ok, workflow} =
      workflow
      |> Ash.load([:steps, :current_step])

    assert Enum.count(workflow.steps) == 4
    assert workflow.current_step.name == :create_step1_resource

    workflow =
      workflow
      |> AshWorkflowTest.Workflow.next!(%{params: %{name: "John Doe"}})
      |> Ash.load!(:current_step)

    assert workflow.state == :sub_workflow
    assert workflow.current_step.name == :create_step2_resource

    {:ok, [step]} =
      Step1
      |> Ash.Query.for_read(:read)
      |> Ash.read()

    assert step.name == "John Doe"

    workflow =
      workflow
      |> AshWorkflowTest.Workflow.next!()
      |> Ash.load!(:current_step)

    assert workflow.state == :sub_workflow
    assert workflow.current_step.name == :destroy_step2_resource

    workflow =
      workflow
      |> AshWorkflowTest.Workflow.next!()
      |> Ash.load!(:current_step)

    assert workflow.state == :done
    refute workflow.current_step
  end
end
