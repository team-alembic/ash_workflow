defmodule AshWorkflowTest do
  use ExUnit.Case
  doctest AshWorkflow

  test "greets the world" do
    {:ok, workflow} = AshWorkflowTest.Workflow.start()

    assert workflow.current_step_index == 0

    {:ok, workflow} =
      workflow
      |> Ash.load(:steps)
      |> dbg()

    assert Enum.count(workflow.steps) == 2

    {:ok, workflow} =
      workflow
      |> AshWorkflowTest.Workflow.next(%{})

    assert workflow.current_step_index == 1
  end
end
