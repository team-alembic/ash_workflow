defmodule AshWorkflowTest.Postgres.SchedulerPauseObanTest do
  @moduledoc """
  `AshWorkflow.Scheduler.pause/1` against real Oban triggers: a paused poll
  queues nothing, a job queued before the pause cancels itself, and the first
  poll after the resume runs both.
  """
  use AshWorkflowTest.DataCase

  alias AshWorkflow.Scheduler
  alias AshWorkflowTest.Postgres.ApprovalWorkflow
  alias AshWorkflowTest.Postgres.FireAtWorkflow

  setup do
    on_exit(fn -> if Scheduler.paused?(), do: Scheduler.resume() end)
  end

  defp state(resource, record), do: Ash.get!(resource, record.id, authorize?: false).state

  defp poll!(trigger) do
    AshOban.schedule_and_run_triggers(trigger)
    Oban.drain_queue(queue: :workflow, with_recursion: true)
  end

  test "an overdue timeout waits for the resume" do
    record =
      FireAtWorkflow.offer!(%{
        candidate_name: "Some Candidate",
        expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
      })

    trigger = {FireAtWorkflow, :__timeout_trigger_pending_expire}

    AshWorkflow.with_scheduler_paused(fn ->
      assert %{failure: 0, discard: 0} = poll!(trigger)
      assert state(FireAtWorkflow, record) == :pending
    end)

    assert %{failure: 0, discard: 0} = poll!(trigger)
    assert state(FireAtWorkflow, record) == :expired
  end

  test "an automatic step queued before the pause cancels, and the poll after the resume runs it" do
    record = ApprovalWorkflow.submit!(%{title: "Q1 report"})

    Scheduler.pause()

    assert %{success: 0, cancelled: 1} = Oban.drain_queue(queue: :workflow)
    assert state(ApprovalWorkflow, record) == :processing

    Scheduler.resume()

    assert %{failure: 0, discard: 0} = poll!(ApprovalWorkflow)
    assert state(ApprovalWorkflow, record) == :review
  end
end
