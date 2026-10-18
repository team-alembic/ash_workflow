defmodule AshWorkflow.SharedRoutedTransitionTest do
  @moduledoc """
  A transition with conditional routes in two steps merges into one action.
  Each route is guarded by the step it leaves, so a route that loops back
  returns to the step the record was in, not to the other step's loop.
  """
  use ExUnit.Case, async: true

  alias AshWorkflowTest.SharedRoutedWorkflow, as: Workflow

  defp in_step(step, remaining) do
    record = Workflow.create!(%{remaining: remaining})

    case step do
      :pending -> record
      :overdue -> Ash.update!(record, action: :escalate)
    end
  end

  for step <- [:pending, :overdue] do
    test "from #{step}, a route that loops back stays in #{step}" do
      assert {:ok, %{state: unquote(step)}} =
               unquote(step) |> in_step(2) |> Ash.update(action: :approve)
    end

    test "from #{step}, the matching route leaves for approved" do
      assert {:ok, %{state: :approved}} =
               unquote(step) |> in_step(1) |> Ash.update(action: :approve)
    end
  end

  test "Info.transition_target/3 previews the same target as the action" do
    record = in_step(:overdue, 2)

    assert AshWorkflow.Info.transition_target(record, :approve) == {:ok, :overdue}
  end
end
