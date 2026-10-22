defmodule AshWorkflow.PreCheckedIdentityTest do
  @moduledoc """
  Ash adds a `before_action` hook to every update on a resource with a
  `pre_check_with` identity, so the transition and timeout actions AshWorkflow
  generates there must not require an atomic update.
  """
  use ExUnit.Case, async: true

  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.PreCheckedIdentityWorkflow, as: Workflow

  defp create(code, deadline_at) do
    Workflow
    |> Ash.Changeset.for_create(:create, %{code: code, deadline_at: deadline_at})
    |> Ash.create()
  end

  test "a generated transition action runs" do
    {:ok, record} = create("a", DateTime.add(DateTime.utc_now(), 1, :day))

    assert {:ok, %{state: :closed}} =
             record |> Ash.Changeset.for_update(:close, %{}) |> Ash.update()
  end

  test "a generated timeout action runs" do
    {:ok, record} = create("b", DateTime.add(DateTime.utc_now(), -1, :minute))

    assert Timeline.run_due(Workflow) == 1
    assert Ash.get!(Workflow, record.id).state == :lapsed
  end

  test "the identity is still checked" do
    {:ok, _record} = create("c", DateTime.utc_now())

    assert {:error, %Ash.Error.Invalid{}} = create("c", DateTime.utc_now())
  end
end
