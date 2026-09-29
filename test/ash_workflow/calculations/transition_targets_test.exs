defmodule AshWorkflow.Calculations.TransitionTargetsTest do
  use ExUnit.Case, async: true

  alias AshWorkflowTest.TransitionTargetWorkflow

  describe "transition_targets calculation" do
    test "maps each transition of the current step to the step it would land in" do
      {:ok, direct} = TransitionTargetWorkflow.create(%{title: "direct", track: :direct})

      direct = Ash.load!(direct, :transition_targets)

      assert direct.transition_targets == %{
               advance: :activated,
               refer: :compliance,
               escalate: nil,
               reject: :rejected
             }
    end

    test "follows the record into its next step" do
      {:ok, record} = TransitionTargetWorkflow.create(%{title: "standard", track: :standard})
      {:ok, in_compliance} = Ash.update(record, action: :advance)

      in_compliance = Ash.load!(in_compliance, :transition_targets)

      assert in_compliance.transition_targets == %{advance: :activated, reject: :rejected}
    end

    test "maps a transition no route matches to nil" do
      {:ok, untracked} = TransitionTargetWorkflow.create(%{title: "untracked"})

      untracked = Ash.load!(untracked, :transition_targets)

      assert untracked.transition_targets.advance == nil
    end

    test "loads a related field a route reads" do
      {:ok, sponsor} = AshWorkflowTest.Reviewer.create(%{name: "Direct"})

      {:ok, sponsored} =
        TransitionTargetWorkflow.create(%{title: "sponsored", sponsor_id: sponsor.id})

      sponsored = Ash.load!(sponsored, :transition_targets)

      assert sponsored.transition_targets.refer == :activated
    end

    test "is an empty map at a terminal step" do
      {:ok, record} = TransitionTargetWorkflow.create(%{title: "rejected"})
      {:ok, rejected} = Ash.update(record, action: :reject)

      rejected = Ash.load!(rejected, :transition_targets)

      assert rejected.transition_targets == %{}
    end
  end
end
