defmodule Mix.Tasks.AshWorkflow.BackfillTransitionLogTest do
  use ExUnit.Case, async: true

  alias AshWorkflowTest.BackfillTransition
  alias AshWorkflowTest.BackfillWorkflow
  alias Mix.Tasks.AshWorkflow.BackfillTransitionLog

  defp drop_log_rows!(record) do
    record
    |> log_rows()
    |> Enum.each(&Ash.destroy!(&1, authorize?: false))
  end

  defp log_rows(record) do
    BackfillTransition
    |> Ash.Query.do_filter(workflow_id: record.id)
    |> Ash.read!(authorize?: false)
  end

  test "seeds one approximate :initial row for a record with no log rows" do
    {:ok, record} = BackfillWorkflow.create(%{title: "backfill me"})
    drop_log_rows!(record)
    assert log_rows(record) == []

    BackfillTransitionLog.run(["AshWorkflowTest.BackfillWorkflow"])

    assert [row] = log_rows(record)
    assert row.from_state == nil
    assert row.to_state == record.state
    assert row.transition_name == :initial
    assert row.triggered_by == :initial
    assert DateTime.compare(row.occurred_at, record.state_entered_at) == :eq
  end

  test "is idempotent: running twice does not double-insert" do
    {:ok, record} = BackfillWorkflow.create(%{title: "backfill me twice"})
    drop_log_rows!(record)

    BackfillTransitionLog.run(["AshWorkflowTest.BackfillWorkflow"])
    BackfillTransitionLog.run(["AshWorkflowTest.BackfillWorkflow"])

    assert [_row] = log_rows(record)
  end

  test "leaves records that already have log rows alone" do
    {:ok, record} = BackfillWorkflow.create(%{title: "already logged"})
    {:ok, record} = Ash.update(record, action: :advance)

    rows_before = log_rows(record)
    assert length(rows_before) == 2

    BackfillTransitionLog.run(["AshWorkflowTest.BackfillWorkflow"])

    assert log_rows(record) == rows_before
  end

  test "raises when the resource has no transition_log configured" do
    assert_raise Mix.Error, ~r/has no `transition_log` configured/, fn ->
      BackfillTransitionLog.run(["AshWorkflowTest.Workflow"])
    end
  end
end
