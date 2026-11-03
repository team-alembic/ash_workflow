defmodule AshWorkflowTest.Postgres.SignalRollbackTest do
  @moduledoc """
  A listener that fails under inline delivery fails the transition that
  emitted the signal, and the transaction rolls the state change back.
  """
  use AshWorkflowTest.DataCase

  alias AshWorkflowTest.Postgres.SignalWorkflow

  defp reload(record), do: Ash.get!(SignalWorkflow, record.id)

  test "a failing listener rolls a single update back" do
    record = SignalWorkflow.create!(%{name: "refuse"})

    assert {:error, _error} = Ash.update(record, action: :approve)
    assert reload(record).state == :review
  end

  test "a failing listener rolls an atomic bulk update back" do
    record = SignalWorkflow.create!(%{name: "refuse"})

    result =
      SignalWorkflow
      |> Ash.Query.do_filter(id: record.id)
      |> Ash.bulk_update(:approve, %{}, strategy: :atomic, return_errors?: true)

    assert result.status == :error
    assert reload(record).state == :review
  end

  test "a listener that succeeds lets the transition commit" do
    record = SignalWorkflow.create!(%{name: "accept"})

    assert {:ok, %{state: :approved}} = Ash.update(record, action: :approve)
    assert reload(record).state == :approved
  end
end
