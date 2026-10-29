defmodule AshWorkflowTest.Postgres.UpsertTest do
  @moduledoc """
  An upsert onto an existing row takes the `ON CONFLICT DO UPDATE` branch,
  which AshPostgres reports as `upsert_action: :update` metadata. That create
  enters no step, so it writes no second `:initial` log row.
  """
  use AshWorkflowTest.DataCase

  require Ash.Query

  alias AshWorkflowTest.Postgres.UpsertTransition
  alias AshWorkflowTest.Postgres.UpsertWorkflow

  defp open(code) do
    UpsertWorkflow
    |> Ash.Changeset.for_create(:open, %{code: code})
    |> Ash.create!()
  end

  defp log_rows(record) do
    UpsertTransition
    |> Ash.Query.filter(workflow_id == ^record.id)
    |> Ash.read!()
    |> Enum.map(&{&1.to_state, &1.triggered_by})
    |> Enum.sort()
  end

  test "an upsert onto an existing row keeps its state and logs nothing" do
    first = open("a")
    Ash.update!(first, action: :close)

    again = open("a")

    assert again.id == first.id
    assert again.__metadata__.upsert_action == :update
    assert again.state == :closed
    assert log_rows(first) == [{:closed, :manual}, {:open, :initial}]
  end

  test "a bulk upsert onto an existing row logs nothing" do
    first = open("b")

    %Ash.BulkResult{status: :success, records: [again]} =
      Ash.bulk_create([%{code: "b"}], UpsertWorkflow, :open, return_records?: true)

    assert again.id == first.id
    assert log_rows(first) == [{:open, :initial}]
  end

  test "an upsert that inserts a row logs its initial step" do
    assert open("c") |> log_rows() == [{:open, :initial}]
  end
end
