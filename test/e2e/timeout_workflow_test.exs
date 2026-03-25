defmodule AshWorkflowTest.E2E.TimeoutWorkflowTest do
  use ExUnit.Case

  alias AshWorkflowTest.TimeoutWorkflow

  describe "DSL compilation" do
    test "resource compiles with timeouts" do
      assert TimeoutWorkflow.__info__(:module) == TimeoutWorkflow
    end
  end

  describe "timeout behavior" do
    test "manual resolve transitions to resolved" do
      {:ok, workflow} = TimeoutWorkflow.create(%{title: "test"})
      {:ok, workflow} = TimeoutWorkflow.resolve(workflow)
      assert workflow.state == :resolved
    end

    test "escalation timeout action transitions to escalated" do
      {:ok, workflow} = TimeoutWorkflow.create(%{title: "escalate"})
      {:ok, escalated} = Ash.update(workflow, action: :__timeout_escalation)
      assert escalated.state == :escalated
    end

    test "reminder timeout action runs without changing state" do
      {:ok, workflow} = TimeoutWorkflow.create(%{title: "remind"})
      {:ok, reminded} = Ash.update(workflow, action: :send_reminder)
      assert reminded.state == :waiting
    end
  end
end
