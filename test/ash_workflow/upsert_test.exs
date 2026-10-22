defmodule AshWorkflow.UpsertTest do
  @moduledoc """
  A create action that upserts onto an existing row enters no step, so it
  writes no transition log row and does not tell the scheduler.
  """
  use ExUnit.Case, async: true

  alias AshWorkflowTest.UpsertLog
  alias AshWorkflowTest.UpsertWorkflow, as: Workflow

  @start [:ash_workflow, :transition, :start]
  @stop [:ash_workflow, :transition, :stop]

  defp open(code) do
    Workflow
    |> Ash.Changeset.for_create(:open, %{code: code})
    |> Ash.create!()
  end

  defp close(record) do
    record |> Ash.Changeset.for_update(:close, %{}) |> Ash.update!()
  end

  defp log_states(record) do
    UpsertLog
    |> Ash.read!()
    |> Enum.filter(&(&1.workflow_id == record.id))
    |> Enum.map(& &1.to_state)
    |> Enum.sort()
  end

  # Handlers run in the emitting process, so matching on self() keeps out
  # events from tests running concurrently.
  defp attach_span_handler do
    handler_id = "upsert-test-#{inspect(make_ref())}"
    pid = self()

    :telemetry.attach_many(
      handler_id,
      [@start, @stop],
      fn event, _measurements, metadata, _config ->
        if self() == pid, do: send(pid, {:span, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp flush_notifications(id) do
    receive do
      {:state_change_notified, ^id} -> flush_notifications(id)
    after
      0 -> :ok
    end
  end

  test "an upsert onto an existing row keeps its state and logs nothing" do
    first = open("a")
    closed = close(first)

    again = open("a")

    assert again.id == first.id
    assert again.state == :closed
    assert again.state_entered_at == closed.state_entered_at
    assert log_states(first) == [:closed, :open]
  end

  test "an upsert that inserts a row logs its initial step" do
    assert open("b") |> log_states() == [:open]
  end

  test "an upsert onto an existing row does not tell the scheduler" do
    first = "c" |> open() |> close()
    flush_notifications(first.id)

    open("c")

    refute_received {:state_change_notified, _id}
  end

  test "an upsert that inserts a row tells the scheduler" do
    record = open("d")

    assert_received {:state_change_notified, id}
    assert id == record.id
  end

  test "an upsert skipped by its upsert_condition logs nothing and does not tell the scheduler" do
    first = "f" |> open() |> close()
    flush_notifications(first.id)

    skipped =
      Workflow
      |> Ash.Changeset.for_create(:open_while_open, %{code: "f"})
      |> Ash.create!(return_skipped_upsert?: true)

    assert skipped.id == first.id
    assert skipped.__metadata__.upsert_skipped
    assert log_states(first) == [:closed, :open]
    refute_received {:state_change_notified, _id}
  end

  test "an upsert onto an existing row still closes the span it opened" do
    first = "e" |> open() |> close()
    attach_span_handler()

    open("e")

    assert_received {:span, @start, %{from_state: nil}}
    assert_received {:span, @stop, %{workflow_id: id, to_state: :closed}}
    assert id == first.id
    refute_received {:span, _event, _metadata}
  end
end
