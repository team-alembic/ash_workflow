defmodule AshWorkflow.InfoTest do
  use ExUnit.Case, async: true

  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Info

  describe "steps/1" do
    test "returns all step entities" do
      steps = Info.steps(AshWorkflowTest.ApprovalWorkflow)
      names = Enum.map(steps, & &1.name)

      assert :review in names
      assert :approved in names
      assert :rejected in names
    end
  end

  describe "step/2" do
    test "returns the step entity by name" do
      step = Info.step(AshWorkflowTest.ApprovalWorkflow, :review)
      assert step.name == :review
      assert Step.manual?(step)
    end

    test "returns nil for unknown step" do
      assert Info.step(AshWorkflowTest.ApprovalWorkflow, :nonexistent) == nil
    end
  end

  describe "transition/2" do
    test "merges the steps a shared transition name leaves" do
      merged = Info.transition(AshWorkflowTest.SharedTransitionWorkflow, :complete)

      assert merged.name == :complete
      assert merged.from == [:step_a, :step_b]
      assert merged.generated_action == :complete
    end

    test "returns one route per declared target, each carrying its step" do
      merged = Info.transition(AshWorkflowTest.SharedTransitionWorkflow, :complete)

      assert merged.routes == [
               %{from: :step_a, to: :done_a, when: nil},
               %{from: :step_b, to: :done_b, when: nil}
             ]
    end

    test "keeps the condition on a conditional route" do
      merged = Info.transition(AshWorkflowTest.SharedConditionalWorkflow, :advance)

      assert merged.from == [:screening, :review, :compliance, :training, :fast_track]

      assert [%{to: :training, when: training_when}, %{to: :fast_track, when: fast_track_when}] =
               Enum.filter(merged.routes, &(&1.from == :compliance))

      refute is_nil(training_when)
      refute is_nil(fast_track_when)

      assert Enum.all?(merged.routes, &(&1.from == :compliance or is_nil(&1.when)))
    end

    test "unions the accepted inputs" do
      assert Info.transition(AshWorkflowTest.AcceptWorkflow, :reject).accepted_inputs == [:reason]
      assert Info.transition(AshWorkflowTest.AcceptWorkflow, :approve).accepted_inputs == []
    end

    test "names the action the transition generated" do
      merged = Info.transition(AshWorkflowTest.AcceptWorkflow, :reject)
      action = Ash.Resource.Info.action(AshWorkflowTest.AcceptWorkflow, merged.generated_action)

      assert action.type == :update
      assert action.accept == merged.accepted_inputs
    end

    test "returns nil for a name no step declares" do
      assert Info.transition(AshWorkflowTest.ApprovalWorkflow, :nonexistent) == nil
    end
  end

  describe "transition_target/3" do
    alias AshWorkflowTest.TransitionTargetWorkflow

    test "resolves each route of a conditional transition" do
      {:ok, direct} = TransitionTargetWorkflow.create(%{title: "direct", track: :direct})
      {:ok, standard} = TransitionTargetWorkflow.create(%{title: "standard", track: :standard})

      assert Info.transition_target(direct, :advance) == {:ok, :activated}
      assert Info.transition_target(standard, :advance) == {:ok, :compliance}
    end

    test "returns nil when no route matches" do
      {:ok, untracked} = TransitionTargetWorkflow.create(%{title: "untracked"})

      assert Info.transition_target(untracked, :advance) == {:ok, nil}
    end

    test "returns nil for a transition the current step does not declare" do
      {:ok, rejected} = TransitionTargetWorkflow.create(%{title: "rejected", track: :direct})
      {:ok, rejected} = Ash.update(rejected, action: :reject)

      assert Info.transition_target(rejected, :advance) == {:ok, nil}
    end

    test "resolves an unconditional transition to its target" do
      {:ok, screening} = TransitionTargetWorkflow.create(%{title: "screening"})

      assert Info.transition_target(screening, :reject) == {:ok, :rejected}
    end

    test "resolves a shared name from the step the record is in" do
      {:ok, record} = TransitionTargetWorkflow.create(%{title: "standard", track: :standard})
      {:ok, in_compliance} = Ash.update(record, action: :advance)

      assert Info.transition_target(in_compliance, :advance) == {:ok, :activated}
    end

    test "returns the error when a route fails to evaluate" do
      {:ok, screening} = TransitionTargetWorkflow.create(%{title: "screening"})

      assert {:error, %Ash.Error.Changes.InvalidAttribute{message: "unreadable"}} =
               Info.transition_target(screening, :escalate)

      assert {:error, _error} = Ash.update(screening, action: :escalate)
    end

    test "reads a related field that is loaded" do
      {:ok, sponsor} = AshWorkflowTest.Reviewer.create(%{name: "Direct"})

      {:ok, sponsored} =
        TransitionTargetWorkflow.create(%{title: "sponsored", sponsor_id: sponsor.id})

      sponsored = Ash.load!(sponsored, :sponsor)

      assert Info.transition_target(sponsored, :refer) == {:ok, :activated}
    end

    test "reads an unloaded related field as nil, as the transition does" do
      {:ok, sponsor} = AshWorkflowTest.Reviewer.create(%{name: "Direct"})

      {:ok, unloaded} =
        TransitionTargetWorkflow.create(%{title: "sponsored", sponsor_id: sponsor.id})

      assert Info.transition_target(unloaded, :refer) == {:ok, nil}
      assert {:error, _no_match} = Ash.update(unloaded, action: :refer)
    end

    test "applies accepted input the same way the action does" do
      {:ok, document} = AshWorkflowTest.AcceptedRouteWorkflow.create(%{title: "undecided"})

      assert Info.transition_target(document, :decide) == {:ok, nil}
      assert Info.transition_target(document, :decide, %{decision: :approve}) == {:ok, :approved}
      assert Info.transition_target(document, :decide, %{decision: :reject}) == {:ok, :rejected}
    end

    test "ignores input the transition does not accept" do
      {:ok, document} = AshWorkflowTest.AcceptedRouteWorkflow.create(%{title: "unsigned"})

      assert Info.transition_target(document, :sign_off, %{signed_by: "someone"}) ==
               {:ok, :review}
    end

    test "agrees with the transition it previews" do
      {:ok, direct} = TransitionTargetWorkflow.create(%{title: "direct", track: :direct})
      {:ok, standard} = TransitionTargetWorkflow.create(%{title: "standard", track: :standard})

      for record <- [direct, standard] do
        {:ok, previewed} = Info.transition_target(record, :advance)
        {:ok, advanced} = Ash.update(record, action: :advance)

        assert advanced.state == previewed
      end
    end

    test "raises for a name no step declares" do
      {:ok, screening} = TransitionTargetWorkflow.create(%{title: "screening"})

      assert_raise ArgumentError, ~r/declares no transition named :nonexistent/, fn ->
        Info.transition_target(screening, :nonexistent)
      end
    end
  end

  describe "available_actions/2" do
    test "returns transition names for manual steps" do
      assert Info.available_actions(AshWorkflowTest.ApprovalWorkflow, :review) == [
               :approve,
               :reject
             ]
    end

    test "returns empty list for terminal steps" do
      assert Info.available_actions(AshWorkflowTest.ApprovalWorkflow, :approved) == []
    end

    test "returns empty list for automatic steps" do
      assert Info.available_actions(AshWorkflowTest.LinearWorkflow, :process) == []
    end

    test "returns empty list for unknown step" do
      assert Info.available_actions(AshWorkflowTest.ApprovalWorkflow, :nonexistent) == []
    end
  end

  describe "terminal?/2" do
    test "returns true for terminal steps" do
      assert Info.terminal?(AshWorkflowTest.ApprovalWorkflow, :approved)
      assert Info.terminal?(AshWorkflowTest.ApprovalWorkflow, :rejected)
    end

    test "returns false for non-terminal steps" do
      refute Info.terminal?(AshWorkflowTest.ApprovalWorkflow, :review)
    end

    test "returns false for non-existent steps" do
      refute Info.terminal?(AshWorkflowTest.ApprovalWorkflow, :nonexistent)
    end
  end

  describe "in_terminal_state?/1" do
    test "returns false for record in initial state" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})
      refute Info.in_terminal_state?(record)
    end

    test "returns true for record in terminal state" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})
      {:ok, approved} = Ash.update(record, action: :approve)
      assert Info.in_terminal_state?(approved)
    end
  end

  describe "initial_step/1" do
    test "returns the initial step" do
      step = Info.initial_step(AshWorkflowTest.ApprovalWorkflow)
      assert step.name == :review
    end

    test "returns step with initial: true flag" do
      step = Info.initial_step(AshWorkflowTest.InitialFlagWorkflow)
      assert step.name == :review
    end
  end

  describe "workflow_graph/1" do
    test "names each transition and its target" do
      graph = Info.workflow_graph(AshWorkflowTest.ApprovalWorkflow)

      assert %{name: :approve, to: :approved, condition: nil} =
               find_transition(graph[:review], :approve)

      assert %{name: :reject, to: :rejected, condition: nil} =
               find_transition(graph[:review], :reject)
    end

    test "carries what a transition accepts" do
      graph = Info.workflow_graph(AshWorkflowTest.AcceptWorkflow)

      assert %{accept: []} = find_transition(graph[:review], :approve)
      assert %{accept: [:reason]} = find_transition(graph[:review], :reject)
    end

    test "gives each conditional route its own edge, carrying its condition" do
      graph = Info.workflow_graph(AshWorkflowTest.ConditionalWorkflow)

      assert [training, fast_track] =
               Enum.filter(graph[:compliance].transitions, &(&1.name == :complete))

      assert %{to: :training, condition: training_condition} = training
      assert %{to: :fast_track, condition: fast_track_condition} = fast_track
      assert inspect(training_condition) == "path_type == :full"
      assert inspect(fast_track_condition) == "path_type == :abbreviated"
    end

    test "marks a transition undoable only when the workflow enables undo" do
      undoable = Info.workflow_graph(AshWorkflowTest.UndoWorkflow)
      assert find_transition(undoable[:review], :approve).undoable?
      refute find_transition(undoable[:review], :escalate).undoable?

      without_undo = Info.workflow_graph(AshWorkflowTest.ApprovalWorkflow)
      refute find_transition(without_undo[:review], :approve).undoable?
    end

    test "reports the action an automatic step runs, and where it goes" do
      graph = Info.workflow_graph(AshWorkflowTest.LinearWorkflow)

      assert %{
               action: :do_processing,
               manual: false,
               on_success: [%{to: :complete, condition: nil}],
               on_error: :failed
             } = graph[:process]
    end

    test "keeps every on_success route with its condition" do
      graph = Info.workflow_graph(AshWorkflowTest.OnSuccessWorkflow)

      assert [interview, rejected, also_qualifies] = graph[:screening].on_success
      assert %{to: :interview} = interview
      assert %{to: :rejected_by_hr} = rejected
      assert %{to: :also_qualifies} = also_qualifies
      assert Enum.all?([interview, rejected, also_qualifies], &(&1.condition != nil))
    end

    test "describes a timeout that transitions and one that runs an action" do
      graph = Info.workflow_graph(AshWorkflowTest.TimeoutWorkflow)

      assert %{
               name: :escalation,
               to: :escalated,
               fire_after: {7, :days},
               field: :state_entered_at,
               action: nil
             } = find_timeout(graph[:waiting], :escalation)

      assert %{name: :reminder, to: nil, fire_after: {2, :days}, action: :send_reminder} =
               find_timeout(graph[:waiting], :reminder)
    end

    test "reports the field a timeout measures against" do
      graph = Info.workflow_graph(AshWorkflowTest.WaitStateWorkflow)

      assert %{field: :release_at, to: :running} = find_timeout(graph[:queued], :release)
    end

    test "marks the initial step" do
      graph = Info.workflow_graph(AshWorkflowTest.ApprovalWorkflow)

      assert graph[:review].initial
      refute graph[:approved].initial
    end

    test "marks the initial step a workflow declares out of order" do
      graph = Info.workflow_graph(AshWorkflowTest.InitialFlagWorkflow)

      assert graph[:review].initial
    end

    test "marks terminal steps" do
      graph = Info.workflow_graph(AshWorkflowTest.ApprovalWorkflow)

      assert graph[:approved].terminal
      assert graph[:rejected].terminal
      refute graph[:review].terminal
    end

    test "marks a wait state" do
      graph = Info.workflow_graph(AshWorkflowTest.WaitStateWorkflow)

      assert graph[:queued].wait_state
      refute graph[:running].wait_state
    end

    test "carries the retry policy of a step and of a timeout" do
      graph = Info.workflow_graph(AshWorkflowTest.RetryWorkflow)

      refute graph[:no_retry].retry

      assert %AshWorkflow.Entities.Retry{max_attempts: 3, backoff: {10, :seconds}} =
               graph[:fixed_backoff].retry

      assert %AshWorkflow.Entities.Retry{max_attempts: 2, backoff: {30, :seconds}} =
               find_timeout(graph[:waiting], :nudge).retry
    end

    test "carries a step's policy" do
      graph = Info.workflow_graph(AshWorkflowTest.PolicyWorkflow)

      assert graph[:manager_review].policy
      refute graph[:approved].policy
    end

    test "repeats each step's name in its entry" do
      graph = Info.workflow_graph(AshWorkflowTest.ApprovalWorkflow)

      assert Enum.all?(graph, fn {name, entry} -> entry.name == name end)
    end
  end

  defp find_transition(step, name), do: Enum.find(step.transitions, &(&1.name == name))
  defp find_timeout(step, name), do: Enum.find(step.timeouts, &(&1.name == name))
end
