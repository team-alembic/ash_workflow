defmodule AshWorkflowTest.E2E.LinearWorkflowTest do
  use ExUnit.Case

  alias AshWorkflowTest.LinearWorkflow

  describe "DSL compilation" do
    test "resource compiles with automatic step chain" do
      assert LinearWorkflow.__info__(:module) == LinearWorkflow
    end
  end

  describe "generated attributes" do
    test "has a state attribute" do
      assert Ash.Resource.Info.attribute(LinearWorkflow, :state)
    end

    test "state attribute defaults to first step name" do
      attr = Ash.Resource.Info.attribute(LinearWorkflow, :state)
      assert attr.default == :process
    end

    test "has a state_entered_at timestamp" do
      assert Ash.Resource.Info.attribute(LinearWorkflow, :state_entered_at)
    end
  end

  describe "generated actions" do
    test "has a start create action" do
      assert Ash.Resource.Info.action(LinearWorkflow, :start)
    end

    test "start action is a create action" do
      action = Ash.Resource.Info.action(LinearWorkflow, :start)
      assert action.type == :create
    end
  end

  describe "generated code interface" do
    test "has start/1 in code interface" do
      assert function_exported?(LinearWorkflow, :start, 1) ||
               function_exported?(LinearWorkflow, :start, 2)
    end
  end

  describe "state machine integration" do
    test "starting a workflow sets state to the first step" do
      {:ok, workflow} = LinearWorkflow.start(%{title: "test"})
      assert workflow.state == :process
    end
  end
end
