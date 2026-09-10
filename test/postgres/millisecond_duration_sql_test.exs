defmodule AshWorkflowTest.Postgres.MillisecondDurationSqlTest do
  @moduledoc """
  A millisecond duration has to survive being compiled into SQL, not only into
  a `DateTime.add/3` call.

  `AshWorkflow.Transformers.AddScheduler` builds a work's `match` as
  `state == step and field <= ago(value, unit)`, and `ago/2` is rendered by
  ash_sql into a `datetime_add` fragment. `:millisecond` is a unit Postgres
  understands in an interval, but nothing in the extension proved that until
  this test ran the comparison against a real database.
  """
  use AshWorkflowTest.DataCase

  require Ash.Expr

  alias AshWorkflowTest.Postgres.ApprovalWorkflow

  defp matching(ms) do
    ApprovalWorkflow
    |> Ash.Query.new()
    |> Ash.Query.do_filter(Ash.Expr.expr(state_entered_at <= ago(^ms, :millisecond)))
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.map(& &1.id)
  end

  test "a millisecond interval compares correctly in Postgres" do
    workflow = ApprovalWorkflow.submit!(%{title: "Q1 report"})

    age_by(workflow, 400, :millisecond)

    assert workflow.id in matching(250)
    refute workflow.id in matching(2_000)
  end
end
