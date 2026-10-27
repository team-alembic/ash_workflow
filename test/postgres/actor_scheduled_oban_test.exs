defmodule AshWorkflowTest.Postgres.ActorScheduledObanTest do
  @moduledoc """
  An automatic step runs through a real Oban on a resource whose read policy
  needs an actor, when `AshWorkflow.Scheduler.Oban` is given one. Without the
  `:actor` option the cron-fired scheduler reads with a `nil` actor, matches no
  rows, and queues no worker. See issue #150.
  """
  use AshWorkflowTest.DataCase

  alias AshWorkflowTest.Postgres.ActorScheduledWorkflow, as: Workflow

  defp create! do
    Workflow
    |> Ash.Changeset.for_create(:create, %{title: "Submission"})
    |> Ash.create!(authorize?: false)
  end

  defp reload(record), do: Ash.get!(Workflow, record.id, authorize?: false)

  test "the read policy hides every record from a nil actor" do
    create!()
    assert Ash.read!(Workflow) == []
  end

  test "an actor-less scheduler run moves the record as the configured actor" do
    record = create!()

    AshOban.schedule_and_run_triggers(Workflow)
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

    assert %{state: :submitted, submitted_by: "submission sync"} = reload(record)
  end
end
