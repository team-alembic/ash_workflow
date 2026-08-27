defmodule AshWorkflow.OnSuccessTest do
  @moduledoc """
  Exercises `on_success`: a repeated entity on automatic steps that fans out
  to different states based on what the step's action computed. Reuses
  `AshWorkflow.Entities.Route` the same way manual `transition` routes do,
  but evaluated after the step's action runs rather than before it.
  """
  use ExUnit.Case, async: true

  alias AshStateMachine.Info, as: SMInfo
  alias AshWorkflowTest.LinearWorkflow
  alias AshWorkflowTest.OnSuccessBackwardLoopWorkflow
  alias AshWorkflowTest.OnSuccessCalculationWorkflow
  alias AshWorkflowTest.OnSuccessFallbackWorkflow
  alias AshWorkflowTest.OnSuccessNilConditionWorkflow
  alias AshWorkflowTest.OnSuccessSelfLoopWorkflow
  alias AshWorkflowTest.OnSuccessShorthandWorkflow
  alias AshWorkflowTest.OnSuccessThreeWayWorkflow
  alias AshWorkflowTest.OnSuccessWorkflow

  describe "state machine generation" do
    test "the step's action transitions to every conditional on_success target" do
      transitions = SMInfo.state_machine_transitions(OnSuccessWorkflow)

      screening_transition = Enum.find(transitions, &(&1.action == :run_screening))

      assert screening_transition
      assert :screening in screening_transition.from
      assert :interview in screening_transition.to
      assert :rejected_by_hr in screening_transition.to
    end

    test "on_error still generates its own transition to the failure state" do
      transitions = SMInfo.state_machine_transitions(OnSuccessWorkflow)

      error_transition =
        Enum.find(transitions, &(&1.action == :__on_error_screening))

      assert error_transition
      assert :screening_failed in error_transition.to
    end
  end

  describe "generated action" do
    test "require_atomic? is disabled, since routing depends on evaluating an expression" do
      action = Ash.Resource.Info.action(OnSuccessWorkflow, :run_screening)
      refute action.require_atomic?
    end
  end

  describe "runtime routing" do
    test "routes to the first matching condition (strong screen)" do
      {:ok, record} = OnSuccessWorkflow.create(%{title: "strong"})
      assert record.state == :screening

      {:ok, result} = Ash.update(record, action: :run_screening)
      assert result.state == :interview
      assert result.screen_score == 8
    end

    test "routes to the second matching condition (weak screen)" do
      {:ok, record} = OnSuccessWorkflow.create(%{title: "weak"})

      {:ok, result} = Ash.update(record, action: :run_screening)
      assert result.state == :rejected_by_hr
      assert result.screen_score == 2
    end

    test "on_error still fires independently of on_success" do
      {:ok, record} = OnSuccessWorkflow.create(%{title: "strong", should_fail: true})

      assert {:error, _error} = Ash.update(record, action: :run_screening)
      assert Ash.get!(OnSuccessWorkflow, record.id).state == :screening

      {:ok, failed} = Ash.update(record, action: :__on_error_screening)
      assert failed.state == :screening_failed
    end

    test "raises a clear error naming the step and the record when no route matches" do
      {:ok, record} = OnSuccessWorkflow.create(%{title: "neutral"})

      assert {:error, error} = Ash.update(record, action: :run_screening)
      message = Exception.message(error)
      assert message =~ "No matching on_success route for step :screening"
      assert message =~ record.id
    end

    test "first matching on_success wins when more than one condition would match" do
      # :also_qualifies (score >= 0) also matches a score of 8, but :interview
      # (score >= 5) is declared first and should win.
      {:ok, record} = OnSuccessWorkflow.create(%{title: "strong"})

      {:ok, result} = Ash.update(record, action: :run_screening)
      assert result.state == :interview
    end

    test "a score exactly on the boundary (== 5) routes via >= 5, not < 5" do
      {:ok, record} = OnSuccessWorkflow.create(%{title: "boundary"})

      {:ok, result} = Ash.update(record, action: :run_screening)
      assert result.state == :interview
      assert result.screen_score == 5
    end

    test "conditions are evaluated against the record after the action ran, not before" do
      # screen_score starts out nil; only after run_screening's own change sets
      # it does either condition become true. If conditions were evaluated
      # before the action (like manual transition routes are), neither would
      # ever match.
      {:ok, record} = OnSuccessWorkflow.create(%{title: "strong"})
      assert record.screen_score == nil

      {:ok, result} = Ash.update(record, action: :run_screening)
      assert result.state == :interview
    end
  end

  describe "inline keyword shorthand" do
    test "step :x, action: :y, on_success: :z, on_error: :w compiles" do
      transitions = SMInfo.state_machine_transitions(OnSuccessShorthandWorkflow)

      tagging_transition = Enum.find(transitions, &(&1.action == :run_tagging))
      assert tagging_transition
      assert :tagging in tagging_transition.from
      assert :verifying in tagging_transition.to
    end

    test "step :x, action: :y, on_success: :z (LinearWorkflow) does not disable require_atomic?" do
      # LinearWorkflow's :process step is declared exactly this way, with no
      # custom change function of its own — so if the inline `on_success: :z`
      # shorthand were somehow treated as conditional, this action would be
      # forced non-atomic. It is not.
      action = Ash.Resource.Info.action(LinearWorkflow, :do_processing)
      assert action.require_atomic?
    end

    test "a block-form bare on_success (no when) is also unconditional" do
      action = Ash.Resource.Info.action(OnSuccessShorthandWorkflow, :run_verification)
      assert action.require_atomic?
    end

    test "a record moves through both unconditional forms on success" do
      {:ok, record} = OnSuccessShorthandWorkflow.create(%{title: "anything"})
      assert record.state == :tagging

      {:ok, result} = Ash.update(record, action: :run_tagging)
      assert result.state == :verifying

      {:ok, result} = Ash.update(result, action: :run_verification)
      assert result.state == :review
    end

    test "on_error still fires for the inline shorthand form" do
      {:ok, record} = OnSuccessShorthandWorkflow.create(%{title: "anything", should_fail: true})

      assert {:error, _error} = Ash.update(record, action: :run_tagging)
      assert Ash.get!(OnSuccessShorthandWorkflow, record.id).state == :tagging

      {:ok, failed} = Ash.update(record, action: :__on_error_tagging)
      assert failed.state == :tagging_failed
    end
  end

  describe "conditional on_success with a trailing unconditional fallback" do
    test "the state machine transitions to every on_success target, conditional and fallback" do
      transitions = SMInfo.state_machine_transitions(OnSuccessFallbackWorkflow)

      triage_transition = Enum.find(transitions, &(&1.action == :run_triage))
      assert triage_transition
      assert :escalated in triage_transition.to
      assert :queued in triage_transition.to
    end

    test "routes to the conditional target when it matches" do
      {:ok, record} = OnSuccessFallbackWorkflow.create(%{priority: :high})

      {:ok, result} = Ash.update(record, action: :run_triage)
      assert result.state == :escalated
    end

    test "falls through to the unconditional target when the condition does not match" do
      {:ok, record} = OnSuccessFallbackWorkflow.create(%{priority: :normal})

      {:ok, result} = Ash.update(record, action: :run_triage)
      assert result.state == :queued
    end

    test "the fallback also catches a record with no priority set" do
      {:ok, record} = OnSuccessFallbackWorkflow.create(%{})

      {:ok, result} = Ash.update(record, action: :run_triage)
      assert result.state == :queued
    end
  end

  describe "a nil attribute in a numeric comparison" do
    test "falls through to the trailing unconditional fallback — nil >= 5 is nil, not false, but the fallback has no condition to fail" do
      {:ok, record} = OnSuccessNilConditionWorkflow.create(%{title: "unscored"})
      assert record.grade_score == nil

      {:ok, result} = Ash.update(record, action: :run_grading)
      assert result.state == :fail
      assert result.grade_score == nil
    end

    test "without a fallback, raises the clear no-match error rather than silently doing something surprising" do
      # OnSuccessWorkflow has no unconditional on_success, so a nil
      # screen_score (title "neutral" never sets it) matches none of
      # `screen_score >= 5`, `screen_score < 5`, or `screen_score >= 0` — each
      # evaluates to nil, not false, and nil never satisfies a route.
      {:ok, record} = OnSuccessWorkflow.create(%{title: "neutral"})
      assert record.screen_score == nil

      assert {:error, error} = Ash.update(record, action: :run_screening)
      assert Exception.message(error) =~ "No matching on_success route for step :screening"
    end
  end

  describe "three or more conditional routes" do
    test "the state machine transitions to every one of the three targets" do
      transitions = SMInfo.state_machine_transitions(OnSuccessThreeWayWorkflow)

      classify_transition = Enum.find(transitions, &(&1.action == :run_classification))
      assert classify_transition
      assert :low in classify_transition.to
      assert :mid in classify_transition.to
      assert :high in classify_transition.to
    end

    test "the middle route matches when it's the only one that should" do
      {:ok, record} = OnSuccessThreeWayWorkflow.create(%{score: 5})

      {:ok, result} = Ash.update(record, action: :run_classification)
      assert result.state == :mid
    end

    test "the first and last routes still match their own ranges" do
      {:ok, low} = OnSuccessThreeWayWorkflow.create(%{score: 1})
      {:ok, low_result} = Ash.update(low, action: :run_classification)
      assert low_result.state == :low

      {:ok, high} = OnSuccessThreeWayWorkflow.create(%{score: 9})
      {:ok, high_result} = Ash.update(high, action: :run_classification)
      assert high_result.state == :high
    end
  end

  describe "on_success routing to a terminal step" do
    test "the record lands on the terminal target and it accepts no outgoing action" do
      {:ok, record} = OnSuccessWorkflow.create(%{title: "strong"})

      {:ok, result} = Ash.update(record, action: :run_screening)
      assert result.state == :interview

      interview_step = AshWorkflow.Info.step(OnSuccessWorkflow, :interview)
      assert interview_step.terminal
    end
  end

  describe "self-loop on_success (retry within a single automatic step)" do
    test "a route can target its own step, compiling without error" do
      transitions = SMInfo.state_machine_transitions(OnSuccessSelfLoopWorkflow)
      attempt_transition = Enum.find(transitions, &(&1.action == :run_attempt))

      assert attempt_transition
      assert :attempting in attempt_transition.from
      assert :attempting in attempt_transition.to
      assert :succeeded in attempt_transition.to
    end

    test "the record stays in the same step across retries, then leaves once the condition flips" do
      {:ok, record} = OnSuccessSelfLoopWorkflow.create(%{})

      {:ok, r1} = Ash.update(record, action: :run_attempt)
      assert r1.state == :attempting
      assert r1.attempts == 1

      {:ok, r2} = Ash.update(r1, action: :run_attempt)
      assert r2.state == :attempting
      assert r2.attempts == 2

      {:ok, r3} = Ash.update(r2, action: :run_attempt)
      assert r3.state == :succeeded
      assert r3.attempts == 3
    end
  end

  describe "backward on_success routing to an earlier step" do
    test "reachability validation does not reject the cycle — the workflow compiles" do
      # Compiling AshWorkflowTest.OnSuccessBackwardLoopWorkflow at all (it is
      # aliased at the top of this module) is itself proof reachability
      # validation accepted the backward route from :collecting to
      # :validating; a rejection would have failed the whole test file to
      # compile.
      transitions = SMInfo.state_machine_transitions(OnSuccessBackwardLoopWorkflow)
      collecting_transition = Enum.find(transitions, &(&1.action == :run_collection))

      assert collecting_transition
      assert :validating in collecting_transition.to
    end

    test "a record loops backward until its condition is satisfied, then moves on" do
      {:ok, record} = OnSuccessBackwardLoopWorkflow.create(%{})
      assert record.state == :validating

      {:ok, r1} = Ash.update(record, action: :run_validation)
      assert r1.state == :collecting
      assert r1.valid == false

      {:ok, r2} = Ash.update(r1, action: :run_collection)
      assert r2.state == :validating
      assert r2.info_count == 1

      {:ok, r3} = Ash.update(r2, action: :run_validation)
      assert r3.state == :collecting, "one round of collection is not enough yet"

      {:ok, r4} = Ash.update(r3, action: :run_collection)
      assert r4.info_count == 2

      {:ok, r5} = Ash.update(r4, action: :run_validation)
      assert r5.state == :submitted
    end
  end

  describe "a condition over a calculation" do
    test "an on_success `when` can reference an expr-backed calculation, not just a plain attribute" do
      {:ok, strong} = OnSuccessCalculationWorkflow.create(%{title: "strong"})
      {:ok, strong_result} = Ash.update(strong, action: :run_screening)
      assert strong_result.state == :interview

      {:ok, weak} = OnSuccessCalculationWorkflow.create(%{title: "weak"})
      {:ok, weak_result} = Ash.update(weak, action: :run_screening)
      assert weak_result.state == :rejected
    end
  end
end
