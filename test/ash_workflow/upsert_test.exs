defmodule AshWorkflow.UpsertTest do
  @moduledoc """
  A create action that upserts onto an existing row enters no step, so it
  writes no transition log row.
  """
  use ExUnit.Case, async: true

  alias AshWorkflowTest.UpsertLog
  alias AshWorkflowTest.UpsertWorkflow, as: Workflow

  defp open(code) do
    Workflow
    |> Ash.Changeset.for_create(:open, %{code: code})
    |> Ash.create!()
  end

  defp log_states(record) do
    UpsertLog
    |> Ash.read!()
    |> Enum.filter(&(&1.workflow_id == record.id))
    |> Enum.map(& &1.to_state)
    |> Enum.sort()
  end

  test "an upsert onto an existing row keeps its state and logs nothing" do
    first = open("a")
    {:ok, closed} = first |> Ash.Changeset.for_update(:close, %{}) |> Ash.update()

    again = open("a")

    assert again.id == first.id
    assert again.state == :closed
    assert again.state_entered_at == closed.state_entered_at
    assert log_states(first) == [:closed, :open]
  end

  test "an upsert that inserts a row logs its initial step" do
    assert open("b") |> log_states() == [:open]
  end
end
