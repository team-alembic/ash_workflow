defmodule AshWorkflow.Calculations.StepCalculationsTest do
  use ExUnit.Case, async: true

  require Ash.Query

  alias Ash.Resource.Info, as: ResourceInfo

  describe "steps calculation" do
    test "returns all step names" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})
      record = Ash.load!(record, :steps)

      assert record.steps == [:review, :approved, :rejected]
    end

    test "is the same regardless of current state" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})
      {:ok, approved} = AshWorkflowTest.ApprovalWorkflow.approve(record)
      approved = Ash.load!(approved, :steps)

      assert approved.steps == [:review, :approved, :rejected]
    end
  end

  describe "current_step calculation" do
    test "returns the current step name" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})
      record = Ash.load!(record, :current_step)

      assert record.current_step == :review
    end

    test "updates after transition" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.approve(record)
      record = Ash.load!(record, :current_step)

      assert record.current_step == :approved
    end
  end

  describe "workflow_terminated_at calculation" do
    test "is nil while the workflow is running" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})
      record = Ash.load!(record, :workflow_terminated_at)

      assert record.workflow_terminated_at == nil
    end

    test "is the instant the record entered a terminal step" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})
      {:ok, approved} = AshWorkflowTest.ApprovalWorkflow.approve(record)
      approved = Ash.load!(approved, :workflow_terminated_at)

      assert %DateTime{} = approved.workflow_terminated_at
      assert approved.workflow_terminated_at == approved.state_entered_at
    end

    test "filters records by whether they have terminated" do
      {:ok, running} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "running"})
      {:ok, closed} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "closed"})
      {:ok, closed} = AshWorkflowTest.ApprovalWorkflow.reject(closed)

      ids =
        AshWorkflowTest.ApprovalWorkflow
        |> Ash.Query.filter(id in ^[running.id, closed.id] and not is_nil(workflow_terminated_at))
        |> Ash.read!(page: false)
        |> Enum.map(& &1.id)

      assert ids == [closed.id]
    end

    test "takes the name set by terminated_at_calculation" do
      workflow = AshWorkflowTest.StatusWorkflow

      assert ResourceInfo.calculation(workflow, :closed_at)
      refute ResourceInfo.calculation(workflow, :workflow_terminated_at)

      record = workflow.create!(%{title: "test"}) |> Ash.load!(:closed_at)

      assert record.closed_at == nil
    end
  end

  describe "loading all calculations together" do
    test "steps, current_step, and available_actions compose in a single load" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})
      record = Ash.load!(record, [:steps, :current_step, :available_actions])

      assert record.steps == [:review, :approved, :rejected]
      assert record.current_step == :review
      assert record.available_actions == [:approve, :reject]
    end
  end
end
