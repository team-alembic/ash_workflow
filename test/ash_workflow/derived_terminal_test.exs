defmodule AshWorkflow.DerivedTerminalTest do
  @moduledoc """
  A step with nothing outgoing is an end state whether or not it says so.
  `terminal: true` remains as an assertion the verifier checks.
  """
  use ExUnit.Case, async: true

  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Info

  describe "Step.terminal?/1" do
    test "a step with nothing outgoing is terminal" do
      assert Step.terminal?(%Step{name: :approved})
    end

    test "an explicit terminal: true is still terminal" do
      assert Step.terminal?(%Step{name: :approved, terminal: true})
    end

    test "a step with transitions is not terminal" do
      assert refute_terminal(%Step{
               name: :review,
               transitions: [%AshWorkflow.Entities.Transition{name: :approve, to: :approved}]
             })
    end

    test "a step with an action is not terminal" do
      assert refute_terminal(%Step{name: :process, action: :do_work})
    end

    test "a step with a timeout is not terminal" do
      assert refute_terminal(%Step{
               name: :waiting,
               timeouts: [%AshWorkflow.Entities.Timeout{name: :expire, transition_to: :expired}]
             })
    end

    test "a step with on_success is not terminal" do
      assert refute_terminal(%Step{
               name: :process,
               action: :do_work,
               on_success: [%AshWorkflow.Entities.Route{to: :done}]
             })
    end

    test "a step with on_error is not terminal" do
      assert refute_terminal(%Step{name: :process, on_error: :failed})
    end

    defp refute_terminal(step), do: not Step.terminal?(step)
  end

  describe "a workflow declaring an undeclared end state" do
    test "reports the derived step as terminal" do
      assert Info.terminal?(AshWorkflowTest.DerivedTerminalWorkflow, :approved)
      assert Info.terminal?(AshWorkflowTest.DerivedTerminalWorkflow, :rejected)
      refute Info.terminal?(AshWorkflowTest.DerivedTerminalWorkflow, :review)
    end

    test "the state machine accepts the transition into it" do
      states =
        AshStateMachine.Info.state_machine_all_states(AshWorkflowTest.DerivedTerminalWorkflow)

      assert :approved in states
    end

    test "the derived step gets no scheduled work" do
      names = Enum.map(Info.scheduled_work(AshWorkflowTest.DerivedTerminalWorkflow), & &1.name)
      refute :approved in names
    end

    test "the graph marks it terminal" do
      graph = Info.workflow_graph(AshWorkflowTest.DerivedTerminalWorkflow)
      assert graph[:approved].terminal
    end

    test "it has no available actions" do
      assert Info.available_actions(AshWorkflowTest.DerivedTerminalWorkflow, :approved) == []
    end
  end
end
