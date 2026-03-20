defmodule AshWorkflow.Transformers.AddCodeInterfaceTest do
  use ExUnit.Case

  test "generates start function" do
    assert {:start, 0} in AshWorkflowTest.ApprovalWorkflow.__info__(:functions)
  end

  test "generates transition functions for manual steps" do
    functions = AshWorkflowTest.ApprovalWorkflow.__info__(:functions)

    assert {:approve, 1} in functions
    assert {:reject, 1} in functions
  end

  test "generates bang variants" do
    functions = AshWorkflowTest.ApprovalWorkflow.__info__(:functions)

    assert {:start!, 0} in functions
    assert {:approve!, 1} in functions
  end

  test "generates functions for all transitions in full pipeline" do
    functions =
      AshWorkflowTest.FullPipeline.__info__(:functions) |> Keyword.keys() |> MapSet.new()

    assert :start in functions
    assert :advance in functions
    assert :approve in functions
    assert :hold in functions
    assert :reactivate in functions
  end
end
