defmodule AshWorkflowTest.Postgres.ActionTimeoutObanTest do
  @moduledoc """
  An action timeout under `AshWorkflow.Scheduler.Oban` fires once for each
  deadline, whatever Oban's pruner does to completed jobs.

  Before `<step>_<timeout>_fired_at`, the trigger set `trigger_once?`, so the
  completed job row was the only record of a firing. Pruning it fired the
  timeout again, and keeping it stopped a second visit to the step from firing
  at all. See issue #106.
  """
  use AshWorkflowTest.DataCase

  import Ecto.Query

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflowTest.Postgres.ActionTimeoutWorkflow, as: Workflow
  alias AshWorkflowTest.Repo

  defp create!(attrs \\ %{}) do
    Workflow |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!(authorize?: false)
  end

  defp transition!(record, action) do
    record |> Ash.Changeset.for_update(action, %{}) |> Ash.update!(authorize?: false)
  end

  defp reload(record), do: Ash.get!(Workflow, record.id, authorize?: false)

  defp run_triggers do
    AshOban.schedule_and_run_triggers(Workflow)
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)
  end

  # What `Oban.Pruner` does with `pruner: [max_age: {1, :day}]`, the setting
  # `mix oban.install` writes, once a completed job is more than a day old.
  defp prune_completed_jobs_older_than_a_day do
    two_days_ago = DateTime.add(DateTime.utc_now(), -2, :day)

    Repo.update_all(from(j in Oban.Job, where: j.state == "completed"),
      set: [scheduled_at: two_days_ago]
    )

    {:ok, pruned} =
      Oban.Engine.prune_jobs(Oban.config(), Oban.Job, max_age: 86_400, limit: 10_000)

    length(pruned)
  end

  test "an action timeout does not run again after Oban prunes its completed job" do
    record = create!()
    age_by(record, 2, :hour)

    run_triggers()
    assert reload(record).reminders == 1

    run_triggers()
    assert reload(record).reminders == 1

    assert prune_completed_jobs_older_than_a_day() > 0
    run_triggers()
    assert reload(record).reminders == 1
  end

  test "an action timeout fires on a second visit to its step" do
    record = create!()
    age_by(record, 2, :hour)
    run_triggers()
    assert reload(record).reminders == 1

    # Ageing only `state_entered_at` would put the new visit before the first
    # firing, which a real visit cannot do. Ageing the fired column too
    # stands in for the first firing having happened hours ago.
    age_field_by(record, :waiting_reminder_fired_at, 3, :hour)
    record = record |> reload() |> transition!(:leave) |> transition!(:come_back)
    assert record.state == :waiting
    age_by(record, 2, :hour)
    run_triggers()

    assert reload(record).reminders == 2
  end

  test "an action timeout does not fire before its deadline" do
    record = create!()
    age_by(record, 30, :minute)

    run_triggers()

    assert reload(record).reminders == 0
    assert reload(record).waiting_reminder_fired_at == nil
  end

  test "a fire_at action timeout fires again once its action moves the field later" do
    record = create!(%{next_check_at: DateTime.add(DateTime.utc_now(), -1, :minute)})

    run_triggers()
    assert reload(record).checks == 1

    run_triggers()
    assert reload(record).checks == 1

    # `run_check` set `next_check_at` an hour out. Moving both columns back
    # stands in for that hour passing.
    age_field_by(record, :waiting_check_fired_at, 61, :minute)
    age_field_by(record, :next_check_at, 1, :minute)
    run_triggers()

    assert reload(record).checks == 2
  end

  test "a fully atomic action timeout fires once and writes its fired column" do
    assert ResourceInfo.action(Workflow, :ping).require_atomic?

    record = create!()
    age_by(record, 4, :hour)

    run_triggers()
    run_triggers()

    record = reload(record)
    assert record.pings == 1
    assert %DateTime{} = record.waiting_ping_fired_at
  end
end
