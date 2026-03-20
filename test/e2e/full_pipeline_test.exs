defmodule AshWorkflowTest.E2E.FullPipelineTest do
  use ExUnit.Case

  alias AshWorkflowTest.FullPipeline

  describe "DSL compilation" do
    test "resource compiles with full pipeline" do
      assert FullPipeline.__info__(:module) == FullPipeline
    end
  end

  describe "generated state machine" do
    test "all step names are valid states" do
      expected_states = [
        :intake,
        :review,
        :on_hold,
        :process,
        :final_review,
        :done,
        :rejected,
        :intake_failed,
        :escalated
      ]

      for state <- expected_states do
        assert state in AshStateMachine.Info.state_machine_all_states(FullPipeline),
               "Expected #{state} to be a valid state"
      end
    end

    test "initial state is the first step" do
      assert {:ok, [:intake]} = AshStateMachine.Info.state_machine_initial_states(FullPipeline)
    end
  end

  describe "generated transition actions" do
    test "has all manual transition actions" do
      expected_actions = [:advance, :reject_at_review, :hold, :reactivate, :reject_on_hold, :approve, :reject_at_final]

      for action_name <- expected_actions do
        assert Ash.Resource.Info.action(FullPipeline, action_name),
               "Expected action #{action_name} to be generated"
      end
    end
  end

  describe "happy path through full pipeline" do
    test "intake → review → process → final_review → done" do
      reviewer = %{role: :reviewer}
      approver = %{role: :approver}

      {:ok, workflow} = FullPipeline.start(%{title: "test"})
      assert workflow.state == :intake

      # Simulate Oban running the automatic intake step
      {:ok, workflow} = Ash.update(workflow, action: :run_intake)
      assert workflow.state == :review

      {:ok, workflow} = FullPipeline.advance(workflow, actor: reviewer)
      assert workflow.state == :process

      # Simulate Oban running the automatic process step
      {:ok, workflow} = Ash.update(workflow, action: :run_processing)
      assert workflow.state == :final_review

      {:ok, workflow} = FullPipeline.approve(workflow, actor: approver)
      assert workflow.state == :done
    end
  end

  describe "rejection at any manual step" do
    test "reject at review" do
      {:ok, workflow} = FullPipeline.start(%{title: "test"})
      # Simulate Oban running the automatic intake step
      {:ok, workflow} = Ash.update(workflow, action: :run_intake)
      {:ok, workflow} = FullPipeline.reject_at_review(workflow, actor: %{role: :reviewer})
      assert workflow.state == :rejected
    end
  end

  describe "hold and reactivate" do
    test "can hold and reactivate from review" do
      reviewer = %{role: :reviewer}

      {:ok, workflow} = FullPipeline.start(%{title: "test"})
      {:ok, workflow} = Ash.update(workflow, action: :run_intake)
      {:ok, workflow} = FullPipeline.hold(workflow, actor: reviewer)
      assert workflow.state == :on_hold

      {:ok, workflow} = FullPipeline.reactivate(workflow, actor: reviewer)
      assert workflow.state == :review
    end
  end

  describe "policy enforcement" do
    test "only reviewers can advance from review" do
      {:ok, workflow} = FullPipeline.start(%{title: "test"})
      {:ok, workflow} = Ash.update(workflow, action: :run_intake)
      non_reviewer = %{role: :approver}
      assert {:error, %Ash.Error.Forbidden{}} = FullPipeline.advance(workflow, actor: non_reviewer)
    end

    test "only approvers can approve at final_review" do
      {:ok, workflow} = FullPipeline.start(%{title: "test"})
      {:ok, workflow} = Ash.update(workflow, action: :run_intake)
      {:ok, workflow} = FullPipeline.advance(workflow, actor: %{role: :reviewer})
      {:ok, workflow} = Ash.update(workflow, action: :run_processing)
      non_approver = %{role: :reviewer}
      assert {:error, %Ash.Error.Forbidden{}} = FullPipeline.approve(workflow, actor: non_approver)
    end
  end
end
