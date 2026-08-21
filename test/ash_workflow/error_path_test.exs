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

    test "the error transition is declared on the generated on_error action" do
      transitions =
        AshStateMachine.Info.state_machine_transitions(AshWorkflowTest.ErrorPathWorkflow)

      error_transition =
        Enum.find(transitions, fn t ->
          t.action == :__on_error_process and :failed in t.to
        end)

      assert error_transition,
             "Expected on_error transition to :failed via :__on_error_process"

      assert :process in error_transition.from
    end

    test "the step's own action does not transition to the error state" do
      transitions =
        AshStateMachine.Info.state_machine_transitions(AshWorkflowTest.ErrorPathWorkflow)

      refute Enum.any?(transitions, fn t ->
               t.action == :do_processing and :failed in t.to
             end),
             "the success action should only reach on_success; the error state " <>
               "is reached by the on_error handler AshOban invokes"
    end

    test "the generated on_error action moves the workflow to the error state" do
      {:ok, record} =
        AshWorkflowTest.ErrorPathWorkflow.create(%{title: "test", should_fail: true})

      assert record.state == :process

      {:ok, failed} = Ash.update(record, action: :__on_error_process)
      assert failed.state == :failed
    end

    test "on_error state is a valid terminal state" do
      states =
        AshStateMachine.Info.state_machine_all_states(AshWorkflowTest.ErrorPathWorkflow)

      assert :failed in states
    end
  end
end
