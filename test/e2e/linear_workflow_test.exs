defmodule AshWorkflowTest.E2E.LinearWorkflowTest do
  use ExUnit.Case

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflowTest.LinearWorkflow

  describe "DSL compilation" do
    test "resource compiles with automatic step chain" do
      assert LinearWorkflow.__info__(:module) == LinearWorkflow
    end
  end

  describe "generated attributes" do
    test "has a state attribute" do
      assert ResourceInfo.attribute(LinearWorkflow, :state)
    end

    test "state attribute defaults to first step name" do
      attr = ResourceInfo.attribute(LinearWorkflow, :state)
      assert attr.default == :process
    end

    test "has a state_entered_at timestamp" do
      assert ResourceInfo.attribute(LinearWorkflow, :state_entered_at)
    end
  end

  describe "generated actions" do
    test "uses a user-defined create action" do
      assert ResourceInfo.action(LinearWorkflow, :create)
    end

    test "create action is a create action" do
      action = ResourceInfo.action(LinearWorkflow, :create)
      assert action.type == :create
    end
  end

  describe "generated code interface" do
    test "has create/1 in code interface" do
      assert function_exported?(LinearWorkflow, :create, 1) ||
               function_exported?(LinearWorkflow, :create, 2)
    end
  end

  describe "state machine integration" do
    test "starting a workflow sets state to the first step" do
      {:ok, workflow} = LinearWorkflow.create(%{title: "test"})
      assert workflow.state == :process
    end
  end
end
