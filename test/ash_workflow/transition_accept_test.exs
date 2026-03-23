defmodule AshWorkflow.TransitionAcceptTest do
  use ExUnit.Case, async: true

  describe "transition accept" do
    test "generated action accepts specified attributes" do
      {:ok, record} = AshWorkflowTest.AcceptWorkflow.start(%{title: "test"})

      {:ok, record} = AshWorkflowTest.AcceptWorkflow.reject(record, %{reason: "Not qualified"})
      assert record.state == :rejected
      assert record.reason == "Not qualified"
    end

    test "transition without accept still works" do
      {:ok, record} = AshWorkflowTest.AcceptWorkflow.start(%{title: "test"})

      {:ok, record} = AshWorkflowTest.AcceptWorkflow.approve(record)
      assert record.state == :approved
    end
  end
end
