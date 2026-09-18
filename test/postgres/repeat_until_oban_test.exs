defmodule AshWorkflowTest.Postgres.RepeatUntilObanTest do
  @moduledoc """
  Exercises `repeat_until` against a real database and a real Oban trigger.

  `AshWorkflowTest.Postgres.RepeatUntilWorkflow` reminds every hour and stops
  once the record has been in the step for 3 hours. `age_by/3` ages
  `state_entered_at` — the anchor the repeat keeps pushing forward — and
  `age_repeat_started_at_by/3` ages `repeat_started_at` — the fixed anchor
  `repeat_until` measures against — independently, so a test can put a record
  on either side of the bound without waiting for a repeat to actually fire.
  """
  use AshWorkflowTest.DataCase

  alias AshWorkflowTest.Postgres.RepeatUntilWorkflow, as: Workflow

  defp submit!, do: Workflow.submit!(%{title: "one"})

  defp run_trigger! do
    AshOban.schedule_and_run_triggers({Workflow, :__timeout_trigger_waiting_reminder})
  end

  test "fires once fire_after has elapsed, while still under the bound" do
    workflow = submit!()
    aged = age_by(workflow, 61, :minute)

    run_trigger!()
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

    reloaded = Ash.get!(Workflow, aged.id, authorize?: false)
    assert reloaded.reminder_count == 1
    assert reloaded.state == :waiting
  end

  test "keeps firing on schedule as long as repeat_started_at is within the bound" do
    workflow = submit!()

    for expected_count <- 1..3 do
      age_by(workflow, 61, :minute)

      run_trigger!()
      assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

      reloaded = Ash.get!(Workflow, workflow.id, authorize?: false)
      assert reloaded.reminder_count == expected_count
      assert reloaded.state == :waiting
    end
  end

  test "stops firing once repeat_started_at is past repeat_until, even though fire_after has elapsed" do
    workflow = submit!()

    age_by(workflow, 61, :minute)
    age_repeat_started_at_by(workflow, 4, :hour)

    run_trigger!()
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

    reloaded = Ash.get!(Workflow, workflow.id, authorize?: false)

    assert reloaded.reminder_count == 0,
           "the bound was already exceeded, so the trigger must not fire"

    assert reloaded.state == :waiting
  end

  test "leaving and re-entering the step resets the bound" do
    workflow = submit!()

    age_by(workflow, 61, :minute)
    age_repeat_started_at_by(workflow, 4, :hour)

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
