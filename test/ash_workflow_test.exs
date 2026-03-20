defmodule AshWorkflowTest do
  use ExUnit.Case

  test "test workflow resource compiles with valid DSL" do
    assert AshWorkflowTest.Workflow.__info__(:module) == AshWorkflowTest.Workflow
  end
end
