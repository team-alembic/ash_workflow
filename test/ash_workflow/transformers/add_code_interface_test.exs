defmodule AshWorkflow.Transformers.AddCodeInterfaceTest do
  use ExUnit.Case

  test "does not generate start functions" do
    functions = AshWorkflowTest.ApprovalWorkflow.__info__(:functions)

    refute {:start, 0} in functions
    refute {:start!, 0} in functions
  end

  test "generates transition functions for manual steps" do
    functions = AshWorkflowTest.ApprovalWorkflow.__info__(:functions)

    assert {:approve, 1} in functions
    assert {:reject, 1} in functions
  end

  test "generates bang variants" do
    functions = AshWorkflowTest.ApprovalWorkflow.__info__(:functions)

    assert {:approve!, 1} in functions
  end

  test "generates functions for all transitions in full pipeline" do
    functions =
      AshWorkflowTest.FullPipeline.__info__(:functions) |> Keyword.keys() |> MapSet.new()

    assert :advance in functions
    assert :approve in functions
    assert :hold in functions
    assert :reactivate in functions
  end
end
