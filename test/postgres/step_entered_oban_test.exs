defmodule AshWorkflowTest.Postgres.StepEnteredObanTest do
  @moduledoc """
  `AshWorkflow.Scheduler.Oban` queues an automatic step's trigger when a record
  enters the step, so the step runs without waiting for the cron poll. See
  issue #151.
  """
  use AshWorkflowTest.DataCase

  alias AshWorkflowTest.Postgres.ApprovalWorkflow

  defp worker_for(action) do
    ApprovalWorkflow
    |> AshOban.Info.oban_triggers()
    |> Enum.find(&(&1.action == action))
    |> Map.fetch!(:worker)
  end

  test "creating a record queues its initial automatic step" do
    workflow = ApprovalWorkflow.submit!(%{title: "Q1 report"})

    assert_enqueued(
      worker: worker_for(:process),
      args: %{"primary_key" => %{"id" => workflow.id}}
    )
  end

  test "the queued job runs the step without a poll" do
    workflow = ApprovalWorkflow.submit!(%{title: "Q1 report"})

    assert %{success: 1, failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow)

    assert Ash.get!(ApprovalWorkflow, workflow.id, authorize?: false).state == :review
  end

  test "a poll after the step has run queues nothing" do
    ApprovalWorkflow.submit!(%{title: "Q1 report"})
    Oban.drain_queue(queue: :workflow)

    AshOban.schedule_and_run_triggers(ApprovalWorkflow, drain_queues?: false)
    Oban.drain_queue(queue: :workflow, with_recursion: false)

    refute_enqueued(worker: worker_for(:process))
  end
end
