defmodule AshWorkflowTest.Postgres.FireAtObanTest do
  @moduledoc """
  A `fire_at` timeout against a real database and a real Oban trigger.

  The trigger's `where` clause is `state = $1 AND expires_at <= now()`, so what
  these tests check is that the record moves once the instant it carries has
  passed, and stays put until then.
  """
  use AshWorkflowTest.DataCase

  alias AshWorkflowTest.Postgres.FireAtWorkflow, as: Workflow

  defp offer(expires_at) do
    Workflow.offer!(%{candidate_name: "Some Candidate", expires_at: expires_at})
  end

  defp run_trigger! do
    AshOban.schedule_and_run_triggers({Workflow, :__timeout_trigger_pending_expire})
  end

  defp state(record), do: Ash.get!(Workflow, record.id, authorize?: false).state

  test "fires once the instant the field holds has passed" do
    record = offer(DateTime.add(DateTime.utc_now(), -1, :hour))

    run_trigger!()
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

    assert state(record) == :expired
  end

  test "does not fire before that instant" do
    record = offer(DateTime.add(DateTime.utc_now(), 1, :hour))

    run_trigger!()
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

    assert state(record) == :pending
  end

  test "does not fire while the field is nil" do
    record = offer(nil)

    run_trigger!()
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

    assert state(record) == :pending
  end

  test "does not fire for a record that has left the step" do
    record = offer(DateTime.add(DateTime.utc_now(), -1, :hour))
    accepted = record |> Ash.Changeset.for_update(:accept, %{}) |> Ash.update!()

    run_trigger!()
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

    assert state(accepted) == :accepted
  end
end
