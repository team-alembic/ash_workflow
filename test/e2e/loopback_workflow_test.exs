defmodule AshWorkflowTest.E2E.LoopbackWorkflowTest do
  use ExUnit.Case

  alias AshWorkflowTest.LoopbackWorkflow

  describe "DSL compilation" do
    test "resource compiles with loop-back transitions" do
      assert LoopbackWorkflow.__info__(:module) == LoopbackWorkflow
    end
  end

  describe "generated transition actions" do
    test "has submit action (draft → review)" do
      assert Ash.Resource.Info.action(LoopbackWorkflow, :submit)
    end

    test "has approve action (review → published)" do
      assert Ash.Resource.Info.action(LoopbackWorkflow, :approve)
    end

    test "has revise action (review → draft)" do
      assert Ash.Resource.Info.action(LoopbackWorkflow, :revise)
    end

    test "has reject action (review → rejected)" do
      assert Ash.Resource.Info.action(LoopbackWorkflow, :reject)
    end
  end

  describe "loop-back flow" do
    test "starts in draft state" do
      {:ok, workflow} = LoopbackWorkflow.start(%{title: "test"})
      assert workflow.state == :draft
    end

    test "submit moves from draft to review" do
      {:ok, workflow} = LoopbackWorkflow.start(%{title: "test"})
      {:ok, workflow} = LoopbackWorkflow.submit(workflow)
      assert workflow.state == :review
    end

    test "revise sends back to draft from review" do
      {:ok, workflow} = LoopbackWorkflow.start(%{title: "test"})
      {:ok, workflow} = LoopbackWorkflow.submit(workflow)
      {:ok, workflow} = LoopbackWorkflow.revise(workflow)
      assert workflow.state == :draft
    end

    test "can loop draft → review → draft → review multiple times" do
      {:ok, workflow} = LoopbackWorkflow.start(%{title: "test"})

      {:ok, workflow} = LoopbackWorkflow.submit(workflow)
      assert workflow.state == :review

      {:ok, workflow} = LoopbackWorkflow.revise(workflow)
      assert workflow.state == :draft

      {:ok, workflow} = LoopbackWorkflow.submit(workflow)
      assert workflow.state == :review

      {:ok, workflow} = LoopbackWorkflow.revise(workflow)
      assert workflow.state == :draft

      {:ok, workflow} = LoopbackWorkflow.submit(workflow)
      assert workflow.state == :review

      {:ok, workflow} = LoopbackWorkflow.approve(workflow)
      assert workflow.state == :published
    end

    test "cannot submit from review (wrong source state)" do
      {:ok, workflow} = LoopbackWorkflow.start(%{title: "test"})
      {:ok, workflow} = LoopbackWorkflow.submit(workflow)
      assert workflow.state == :review
      assert {:error, _} = LoopbackWorkflow.submit(workflow)
    end

    test "cannot revise from draft (wrong source state)" do
      {:ok, workflow} = LoopbackWorkflow.start(%{title: "test"})
      assert workflow.state == :draft
      assert {:error, _} = LoopbackWorkflow.revise(workflow)
    end
  end
end
