defmodule AshWorkflow.SharedTransitionTest do
  use ExUnit.Case

  alias AshWorkflowTest.SharedTransitionWorkflow

  describe "DSL compilation" do
    test "compiles with same transition name across steps" do
      assert SharedTransitionWorkflow.__info__(:module) == SharedTransitionWorkflow
    end
  end

  describe "generated actions" do
    test "generates one :reject action (shared across steps)" do
      action = Ash.Resource.Info.action(SharedTransitionWorkflow, :reject)
      assert action
      assert action.type == :update
    end

    test "generates one :complete action (shared across steps, different targets)" do
      action = Ash.Resource.Info.action(SharedTransitionWorkflow, :complete)
      assert action
      assert action.type == :update
    end
  end

  describe "state machine" do
    test "generates transitions for both steps" do
      transitions = AshStateMachine.Info.state_machine_transitions(SharedTransitionWorkflow)

      # :reject from step_a → rejected
      assert Enum.any?(transitions, fn t ->
               t.action == :reject and :step_a in t.from and :rejected in t.to
             end)

      # :reject from step_b → rejected
      assert Enum.any?(transitions, fn t ->
               t.action == :reject and :step_b in t.from and :rejected in t.to
             end)

      # :complete from step_a → done_a
      assert Enum.any?(transitions, fn t ->
               t.action == :complete and :step_a in t.from and :done_a in t.to
             end)

      # :complete from step_b → done_b
      assert Enum.any?(transitions, fn t ->
               t.action == :complete and :step_b in t.from and :done_b in t.to
             end)
    end
  end

  describe "runtime: same target from different steps" do
    test "reject from step_a goes to rejected" do
      {:ok, workflow} = SharedTransitionWorkflow.create(%{title: "test"})
      assert workflow.state == :step_a

      {:ok, workflow} = Ash.update(workflow, action: :reject)
      assert workflow.state == :rejected
    end

    test "reject from step_b goes to rejected" do
      {:ok, workflow} = SharedTransitionWorkflow.create(%{title: "test"})
      {:ok, workflow} = Ash.update(workflow, action: :move_to_b)
      assert workflow.state == :step_b

      {:ok, workflow} = Ash.update(workflow, action: :reject)
      assert workflow.state == :rejected
    end
  end

  describe "runtime: different targets from different steps" do
    test "complete from step_a goes to done_a" do
      {:ok, workflow} = SharedTransitionWorkflow.create(%{title: "test"})
      assert workflow.state == :step_a

      {:ok, workflow} = Ash.update(workflow, action: :complete)
      assert workflow.state == :done_a
    end

    test "complete from step_b goes to done_b" do
      {:ok, workflow} = SharedTransitionWorkflow.create(%{title: "test"})
      {:ok, workflow} = Ash.update(workflow, action: :move_to_b)
      assert workflow.state == :step_b

      {:ok, workflow} = Ash.update(workflow, action: :complete)
      assert workflow.state == :done_b
    end
  end
end
