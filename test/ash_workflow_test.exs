defmodule AshWorkflowTest do
  alias AshWorkflowTest.Step1
  use ExUnit.Case
  doctest AshWorkflow

  test "greets the world" do
    {:ok, workflow} = AshWorkflowTest.Workflow.start()

    assert workflow.current_step == :create_step1_resource

    {:ok, workflow} =
      workflow
      |> Ash.load(:steps)

    assert Enum.count(workflow.steps) == 3

    {:ok, workflow} =
      workflow
      |> AshWorkflowTest.Workflow.next(%{params: %{name: "John Doe"}})

    assert workflow.current_step == :sub_workflow

    {:ok, [step]} =
      Step1
      |> Ash.Query.for_read(:read)
      |> Ash.read()

    assert step.name == "John Doe"

    {:ok, workflow} =
      workflow
      |> AshWorkflowTest.Workflow.next()

    assert workflow.current_step == :sub_workflow

    {:ok, workflow} =
      workflow
      |> AshWorkflowTest.Workflow.next()

    assert workflow.current_step == :done
  end
end
