defmodule AshWorkflowTest.E2E.ApprovalWorkflowTest do
  use ExUnit.Case

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflowTest.ApprovalWorkflow

  describe "DSL compilation" do
    test "resource compiles with manual steps and transitions" do
      assert ApprovalWorkflow.__info__(:module) == ApprovalWorkflow
    end
  end

  describe "generated transition actions" do
    test "has an approve action" do
      assert ResourceInfo.action(ApprovalWorkflow, :approve)
    end

    test "has a reject action" do
      assert ResourceInfo.action(ApprovalWorkflow, :reject)
    end

    test "transition actions are update actions" do
      approve = ResourceInfo.action(ApprovalWorkflow, :approve)
      reject = ResourceInfo.action(ApprovalWorkflow, :reject)
      assert approve.type == :update
      assert reject.type == :update
    end
  end

  describe "generated code interface" do
    test "has approve in code interface" do
      assert function_exported?(ApprovalWorkflow, :approve, 1) ||
               function_exported?(ApprovalWorkflow, :approve, 2)
    end

    test "has reject in code interface" do
      assert function_exported?(ApprovalWorkflow, :reject, 1) ||
               function_exported?(ApprovalWorkflow, :reject, 2)
    end
  end

  describe "manual transition flow" do
    test "starting places workflow in the first manual step" do
      {:ok, workflow} = ApprovalWorkflow.start(%{title: "test"})
      assert workflow.state == :review
    end

    test "approve transitions to approved" do
      {:ok, workflow} = ApprovalWorkflow.start(%{title: "test"})
      {:ok, workflow} = ApprovalWorkflow.approve(workflow)
      assert workflow.state == :approved
    end

    test "reject transitions to rejected" do
      {:ok, workflow} = ApprovalWorkflow.start(%{title: "test"})
      {:ok, workflow} = ApprovalWorkflow.reject(workflow)
      assert workflow.state == :rejected
    end

    test "cannot transition from a terminal state" do
      {:ok, workflow} = ApprovalWorkflow.start(%{title: "test"})
      {:ok, workflow} = ApprovalWorkflow.approve(workflow)
      assert workflow.state == :approved
      assert {:error, _} = ApprovalWorkflow.reject(workflow)
    end
  end
end
