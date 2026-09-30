defmodule AshWorkflowTest.Postgres.RefuseStaleTransitionsTest do
  @moduledoc """
  Shows the stale-transition refusal against a real filtered `UPDATE`, on
  both the non-atomic path a conditional transition takes and the atomic path
  a static one takes.
  """
  use AshWorkflowTest.DataCase

  alias Ash.Error.Changes.StaleRecord
  alias AshWorkflowTest.Postgres.StaleTransitionWorkflow
  alias AshWorkflowTest.Repo
  alias Ecto.Adapters.SQL.Sandbox

  defp submit(attrs \\ %{}) do
    StaleTransitionWorkflow.submit!(Map.merge(%{candidate_name: "Ada"}, attrs))
  end

  defp reload(record), do: Ash.get!(StaleTransitionWorkflow, record.id)

  defp stale_record_error?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%StaleRecord{}, &1))

  defp stale_record_error?(_error), do: false

  test "refuses a conditional transition from a copy loaded before an attribute a route reads changed" do
    stale = submit()
    Ash.update!(stale, %{path_type: :family}, action: :classify)

    assert {:error, error} = Ash.update(stale, action: :advance)
    assert stale_record_error?(error)
    assert %{state: :screening, path_type: :family} = reload(stale)
  end

  test "refuses a static transition from a copy loaded before the record changed step" do
    stale = submit()
    Ash.update!(stale, action: :advance)

    assert {:error, error} = Ash.update(stale, action: :reject)
    assert stale_record_error?(error)
    assert reload(stale).state == :interviewing
  end

  test "lets exactly one of two concurrent transitions from the same loaded copy through" do
    Sandbox.mode(Repo, {:shared, self()})
    copy = submit()

    results =
      [:advance, :reject]
      |> Enum.map(fn action -> Task.async(fn -> Ash.update(copy, action: action) end) end)
      |> Task.await_many()

    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, error}] = Enum.filter(results, &match?({:error, _}, &1))
    assert stale_record_error?(error)
    assert reload(copy).state == winner.state
  end
end
