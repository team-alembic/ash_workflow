defmodule AshWorkflow.Scheduler.ObanStepEnteredTest do
  @moduledoc """
  A step whose action routes the record back into the same step is not queued
  again by `AshWorkflow.Scheduler.Oban`. The route means "nothing to do yet",
  so the record waits for the cron poll. See issue #151.
  """
  use AshWorkflowTest.EtsCase, async: true
  use Oban.Testing, repo: AshWorkflowTest.Repo, prefix: "public"

  alias AshWorkflowTest.OnSuccessSelfLoopWorkflow, as: Workflow

  defp worker do
    Workflow
    |> AshOban.Info.oban_triggers()
    |> Enum.find(&(&1.action == :run_attempt))
    |> Map.fetch!(:worker)
  end

  defp reload(record), do: Ash.get!(Workflow, record.id, authorize?: false)

  test "creating a record queues the step" do
    record = Workflow.create!()

    assert_enqueued(worker: worker(), args: %{"primary_key" => %{"id" => record.id}})
  end

  test "the step's job routing back to the step queues no second job" do
    record = Workflow.create!()

    assert %{success: 1} = Oban.drain_queue(queue: :workflow, with_recursion: true)

    record = reload(record)
    assert record.state == :attempting
    assert record.attempts == 1
    refute_enqueued(worker: worker())
  end

  # Run outside a job, so no executing job is there for Oban's uniqueness check
  # to collide with. Only `AshWorkflow.Changes.RecordEvent` decides here.
  test "the step's action routing back to the step outside a job queues nothing" do
    record = Workflow.create!()
    Oban.drain_queue(queue: :workflow)

    record =
      record
      |> reload()
      |> Ash.Changeset.for_update(:run_attempt, %{})
      |> Ash.update!(authorize?: false)

    assert record.state == :attempting
    assert record.attempts == 2
    refute_enqueued(worker: worker())
  end
end
