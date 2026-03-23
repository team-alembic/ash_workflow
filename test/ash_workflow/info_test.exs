defmodule AshWorkflow.InfoTest do
  use ExUnit.Case, async: true

  alias AshWorkflow.Info

  describe "steps/1" do
    test "returns all step entities" do
      steps = Info.steps(AshWorkflowTest.ApprovalWorkflow)
      names = Enum.map(steps, & &1.name)

      assert :review in names
      assert :approved in names
      assert :rejected in names
    end
  end

  describe "step/2" do
    test "returns the step entity by name" do
      step = Info.step(AshWorkflowTest.ApprovalWorkflow, :review)
      assert step.name == :review
      assert step.manual == true
    end

    test "returns nil for unknown step" do
      assert Info.step(AshWorkflowTest.ApprovalWorkflow, :nonexistent) == nil
    end
  end

  describe "available_actions/2" do
    test "returns transition names for manual steps" do
      assert Info.available_actions(AshWorkflowTest.ApprovalWorkflow, :review) == [
               :approve,
               :reject
             ]
    end

    test "returns empty list for terminal steps" do
      assert Info.available_actions(AshWorkflowTest.ApprovalWorkflow, :approved) == []
    end

    test "returns empty list for automatic steps" do
      assert Info.available_actions(AshWorkflowTest.LinearWorkflow, :process) == []
    end

    test "returns empty list for unknown step" do
      assert Info.available_actions(AshWorkflowTest.ApprovalWorkflow, :nonexistent) == []
    end
  end
end
