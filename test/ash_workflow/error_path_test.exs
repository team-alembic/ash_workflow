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

  describe "AshWorkflow.Scheduler.execute/3" do
    alias AshWorkflow.Entities.Retry
    alias AshWorkflow.Scheduler
    alias AshWorkflowTest.RaisingStepWorkflow

    defp work_for(:process) do
      RaisingStepWorkflow
      |> AshWorkflow.Info.scheduled_work()
      |> Enum.find(&(&1.step == :process))
    end

    test "routes a change that raises to on_error" do
      # The change raises from change/3, so the exception escapes while
      # Ash.Changeset.for_update/4 is still building the changeset and never
      # reaches Ash.update/2. Before execute/3 rescued it, a raising step
      # bypassed on_error entirely: the caller saw the exception and the record
      # stayed in :process with nothing to retry it out of.
      {:ok, record} = RaisingStepWorkflow.create(%{title: "test"})

      assert {:ok, failed} = Scheduler.execute(work_for(:process), record)
      assert failed.state == :failed
    end

    test "with max_attempts: 1, the default, a failure runs on_error on the first attempt" do
      {:ok, record} = RaisingStepWorkflow.create(%{title: "test"})

      work = work_for(:process)

      assert work.retry.max_attempts == 1
      assert {:ok, failed} = Scheduler.execute(work, record)
      assert failed.state == :failed
    end

    test "with max_attempts greater than 1, a failing attempt returns {:retry, delay_ms} instead" do
      {:ok, record} = RaisingStepWorkflow.create(%{title: "test"})

      work = %{work_for(:process) | retry: %Retry{max_attempts: 3, backoff: {10, :seconds}}}

      assert {:retry, 10_000} = Scheduler.execute(work, record, attempt: 1)

      # It has not been routed to on_error: the record is exactly as it was
      # before the attempt, still in :process.
      assert Ash.get!(RaisingStepWorkflow, record.id).state == :process
    end

    test "the final attempt still runs on_error" do
      {:ok, record} = RaisingStepWorkflow.create(%{title: "test"})

      work = %{work_for(:process) | retry: %Retry{max_attempts: 2, backoff: {10, :seconds}}}

      assert {:ok, failed} = Scheduler.execute(work, record, attempt: 2)
      assert failed.state == :failed
    end
  end
end
