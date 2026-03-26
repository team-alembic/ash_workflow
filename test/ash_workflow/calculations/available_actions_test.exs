defmodule AshWorkflow.Calculations.AvailableActionsTest do
  use ExUnit.Case, async: true

  describe "available_actions calculation" do
    test "returns transition names for a record in a manual step" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})
      assert record.state == :review

      record = Ash.load!(record, :available_actions)
      assert record.available_actions == [:approve, :reject]
    end

    test "returns empty list for a record in a terminal step" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.approve(record)
      assert record.state == :approved

      record = Ash.load!(record, :available_actions)
      assert record.available_actions == []
    end

    test "returns empty list for a record in an automatic step" do
      {:ok, record} = AshWorkflowTest.LinearWorkflow.create(%{title: "test"})
      assert record.state == :process

      record = Ash.load!(record, :available_actions)
      assert record.available_actions == []
    end
  end

  describe "authorization-aware filtering" do
    test "returns all actions when no actor is provided" do
      {:ok, record} = AshWorkflowTest.PolicyWorkflow.create(%{title: "test"})
      assert record.state == :manager_review

      record = Ash.load!(record, :available_actions)
      assert record.available_actions == [:approve, :reject]
    end

    test "returns permitted actions for authorized actor" do
      {:ok, record} =
        AshWorkflowTest.PolicyWorkflow.create(%{title: "test"}, actor: %{role: :manager})

      record = Ash.load!(record, :available_actions, actor: %{role: :manager})
      assert record.available_actions == [:approve, :reject]
    end

    test "returns empty list for unauthorized actor" do
      {:ok, record} =
        AshWorkflowTest.PolicyWorkflow.create(%{title: "test"}, actor: %{role: :manager})

      record = Ash.load!(record, :available_actions, actor: %{role: :viewer})
      assert record.available_actions == []
    end
  end
end
