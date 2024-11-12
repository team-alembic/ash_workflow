defmodule AshWorkflowTest do
  use ExUnit.Case
  doctest AshWorkflow

  test "greets the world" do
    assert AshWorkflowTest.Workflow.spark_dsl_config()
  end
end
