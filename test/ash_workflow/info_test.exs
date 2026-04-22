defmodule AshWorkflow.InfoTest do
  use ExUnit.Case, async: true

  alias AshWorkflow.Entities.Step
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
      assert Step.manual?(step)
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

  describe "terminal?/2" do
    test "returns true for terminal steps" do
      assert Info.terminal?(AshWorkflowTest.ApprovalWorkflow, :approved)
      assert Info.terminal?(AshWorkflowTest.ApprovalWorkflow, :rejected)
    end

    test "returns false for non-terminal steps" do
      refute Info.terminal?(AshWorkflowTest.ApprovalWorkflow, :review)
    end

    test "returns false for non-existent steps" do
      refute Info.terminal?(AshWorkflowTest.ApprovalWorkflow, :nonexistent)
    end
  end

  describe "in_terminal_state?/1" do
    test "returns false for record in initial state" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})
      refute Info.in_terminal_state?(record)
    end

    test "returns true for record in terminal state" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})
      {:ok, approved} = Ash.update(record, action: :approve)
      assert Info.in_terminal_state?(approved)
    end
  end

  describe "initial_step/1" do
    test "returns the initial step" do
      step = Info.initial_step(AshWorkflowTest.ApprovalWorkflow)
      assert step.name == :review
    end

    test "returns step with initial: true flag" do
      step = Info.initial_step(AshWorkflowTest.InitialFlagWorkflow)
      assert step.name == :review
    end
  end

  describe "workflow_graph/1" do
    test "returns graph with manual step transitions" do
      graph = Info.workflow_graph(AshWorkflowTest.ApprovalWorkflow)

      assert %{transitions: transitions} = graph[:review]
      assert :approved in transitions
      assert :rejected in transitions
    end

    test "returns graph with automatic step on_success" do
      graph = Info.workflow_graph(AshWorkflowTest.LinearWorkflow)

      assert %{on_success: :complete, on_error: :failed} = graph[:process]
    end

    test "marks terminal steps" do
      graph = Info.workflow_graph(AshWorkflowTest.ApprovalWorkflow)

      assert graph[:approved].terminal
      assert graph[:rejected].terminal
      refute graph[:review].terminal
    end

    test "includes timeout targets" do
      graph = Info.workflow_graph(AshWorkflowTest.TimeoutWorkflow)

      waiting = graph[:waiting]
      assert {:escalation, :escalated} in waiting.timeouts
    end

    test "includes conditional route targets" do
      graph = Info.workflow_graph(AshWorkflowTest.ConditionalWorkflow)

      compliance = graph[:compliance]
      assert :training in compliance.transitions
      assert :fast_track in compliance.transitions
    end
  end
end
