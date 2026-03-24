defmodule AshWorkflow.Calculations.StepCalculationsTest do
  use ExUnit.Case, async: true

  describe "steps calculation" do
    test "returns all step names" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.start(%{title: "test"})
      record = Ash.load!(record, :steps)

      assert record.steps == [:review, :approved, :rejected]
    end

    test "is the same regardless of current state" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.start(%{title: "test"})
      {:ok, approved} = AshWorkflowTest.ApprovalWorkflow.approve(record)
      approved = Ash.load!(approved, :steps)

      assert approved.steps == [:review, :approved, :rejected]
    end
  end

  describe "current_step calculation" do
    test "returns the current step name" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.start(%{title: "test"})
      record = Ash.load!(record, :current_step)

      assert record.current_step == :review
    end

    test "updates after transition" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.start(%{title: "test"})
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.approve(record)
      record = Ash.load!(record, :current_step)

      assert record.current_step == :approved
    end
  end

  describe "loading all calculations together" do
    test "steps, current_step, and available_actions compose in a single load" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.start(%{title: "test"})
      record = Ash.load!(record, [:steps, :current_step, :available_actions])

      assert record.steps == [:review, :approved, :rejected]
      assert record.current_step == :review
      assert record.available_actions == [:approve, :reject]
    end
  end
end
