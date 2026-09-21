defmodule AshWorkflowTest.Postgres.EveryUntilObanTest do
  @moduledoc """
  Exercises `until` against a real database and a real Oban trigger.

  `AshWorkflowTest.Postgres.EveryUntilWorkflow` reminds every hour and stops
  once the record has been in the step for 3 hours. `interval` is measured
  against `waiting_reminder_last_fired_at`, the `every`'s own last-fired
  column, falling back to `state_entered_at` until the first fire, and `until`
  against `state_entered_at`. `age_field_by/4` ages either
  one independently, so a test can put a record on either side of a bound
  without waiting for a fire to actually happen.
  """
  use AshWorkflowTest.DataCase

  alias AshWorkflowTest.Postgres.EveryUntilWorkflow, as: Workflow

  defp submit!, do: Workflow.submit!(%{title: "one"})

  defp run_trigger! do
    AshOban.schedule_and_run_triggers({Workflow, :__every_trigger_waiting_reminder})
  end

  test "fires one interval after entry when the every has never fired" do
    workflow = submit!()

    run_trigger!()
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)
    assert Ash.get!(Workflow, workflow.id, authorize?: false).reminder_count == 0

    workflow = age_field_by(workflow, :state_entered_at, 61, :minute)

    run_trigger!()
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

    reloaded = Ash.get!(Workflow, workflow.id, authorize?: false)
    assert reloaded.reminder_count == 1
    assert reloaded.state == :waiting
  end

  test "fires once the interval has elapsed, while still under the bound" do
    workflow = submit!()
    aged = age_field_by(workflow, :waiting_reminder_last_fired_at, 61, :minute)

    run_trigger!()
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

    reloaded = Ash.get!(Workflow, aged.id, authorize?: false)
    assert reloaded.reminder_count == 1
    assert reloaded.state == :waiting
  end

  test "keeps firing on schedule as long as state_entered_at is within the bound" do
    workflow = submit!()

    for expected_count <- 1..3 do
      age_field_by(workflow, :waiting_reminder_last_fired_at, 61, :minute)

      run_trigger!()
      assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

      reloaded = Ash.get!(Workflow, workflow.id, authorize?: false)
      assert reloaded.reminder_count == expected_count
      assert reloaded.state == :waiting
    end
  end

  test "stops firing once state_entered_at is past until, even though the interval has elapsed" do
    workflow = submit!()

    age_field_by(workflow, :waiting_reminder_last_fired_at, 61, :minute)
    age_by(workflow, 4, :hour)

    run_trigger!()
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

    reloaded = Ash.get!(Workflow, workflow.id, authorize?: false)

    assert reloaded.reminder_count == 0,
           "the bound was already exceeded, so the trigger must not fire"

    assert reloaded.state == :waiting
  end

  test "leaving and re-entering the step resets the bound" do
    workflow = submit!()

    age_field_by(workflow, :waiting_reminder_last_fired_at, 61, :minute)
    age_by(workflow, 4, :hour)

    run_trigger!()
    Oban.drain_queue(queue: :workflow, with_recursion: true)
    assert Ash.get!(Workflow, workflow.id, authorize?: false).reminder_count == 0

    resolved =
      workflow
      |> Ash.Changeset.for_update(:resolve, %{})
      |> Ash.update!()

    assert resolved.state == :resolved
  end
end
