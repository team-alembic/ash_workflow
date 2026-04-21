defmodule AshWorkflow.ErrorPathTest do
  use ExUnit.Case, async: true

  describe "on_error transition" do
    test "successful automatic step transitions to on_success state" do
      {:ok, record} =
        AshWorkflowTest.ErrorPathWorkflow.create(%{title: "test", should_fail: false})

      assert record.state == :process

      {:ok, result} = Ash.update(record, action: :do_processing)
      assert result.state == :done
    end

    test "state machine allows on_error transition path" do
      transitions =
        AshStateMachine.Info.state_machine_transitions(AshWorkflowTest.ErrorPathWorkflow)

      error_transition =
        Enum.find(transitions, fn t ->
          t.action == :do_processing and :failed in t.to
        end)

      assert error_transition, "Expected on_error transition to :failed via :do_processing"
      assert :process in error_transition.from
    end

    test "on_error state is a valid terminal state" do
      states =
        AshStateMachine.Info.state_machine_all_states(AshWorkflowTest.ErrorPathWorkflow)

      assert :failed in states
    end
  end
end
