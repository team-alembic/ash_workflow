defmodule AshWorkflowTest do
  use ExUnit.Case
  doctest AshWorkflow

  test "greets the world" do
    assert AshWorkflow.hello() == :world
  end
end
