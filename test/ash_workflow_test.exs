defmodule AshWorkflowTest do
  use ExUnit.Case
  doctest AshWorkflow

  test "greets the world" do
    assert {:ok, _workflow} = AshWorkflowTest.Workflow.start()
  end
end
