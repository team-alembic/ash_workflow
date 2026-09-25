defmodule AshWorkflowTest.Postgres.WallClockObanTest do
  @moduledoc """
  `every ... at` against a real database and a real Oban trigger.

  The trigger's `where` clause is a Postgres fragment: it reads
  `candidate_time_zone` out of the row, shifts `now()` into that zone, checks
  the ISO day against `on` and the local time against `at`, and compares the
  last fire to the most recent occurrence. Nothing in Elixir decides due-ness
  here, which is the whole point of this file —
  `AshWorkflow.Scheduler.WallClockEveryTest` covers the Elixir side.

  `set_field/3` places `state_entered_at` and `waiting_digest_last_fired_at`
  on either side of that occurrence, so no test waits for a real 09:00.
  """
  use AshWorkflowTest.DataCase

  alias AshWorkflowTest.Postgres.WallClockWorkflow, as: Workflow

  @weekdays [:mon, :tue, :wed, :thu, :fri]

  defp submit!(zone), do: Workflow.submit!(%{title: "one", candidate_time_zone: zone})

  defp run_trigger! do
    AshOban.schedule_and_run_triggers({Workflow, :__every_trigger_waiting_digest})
  end

  defp drain! do
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)
  end

  defp digest_count(record), do: Ash.get!(Workflow, record.id, authorize?: false).digest_count

  defp schedule(zone) do
    {:ok, days} = AshWorkflow.WallClock.to_day_numbers(@weekdays)

    %AshWorkflow.WallClock{time: ~T[09:00:00], days: days, time_zone: zone}
  end

  # The most recent 09:00 in the zone, computed in Elixir. The fragment has to
  # agree with this, which is what these tests check.
  defp last_occurrence(zone) do
    AshWorkflow.WallClock.previous_occurrence(schedule(zone), zone, DateTime.utc_now())
  end

  defp before_occurrence(zone), do: DateTime.add(last_occurrence(zone), -1, :hour)

  test "does not fire on entry, even when today's occurrence has already passed" do
    workflow = submit!("Australia/Sydney")

    run_trigger!()
    drain!()

    assert digest_count(workflow) == 0
  end

  test "fires when the record entered the step before the most recent occurrence" do
    zone = "Australia/Sydney"
    workflow = submit!(zone)

    set_field(workflow, :state_entered_at, before_occurrence(zone))

    run_trigger!()
    drain!()

    assert digest_count(workflow) == 1
  end

  test "does not fire twice for one occurrence" do
    zone = "Australia/Sydney"
    workflow = submit!(zone)

    set_field(workflow, :state_entered_at, before_occurrence(zone))

    run_trigger!()
    drain!()
    run_trigger!()
    drain!()

    assert digest_count(workflow) == 1
  end

  test "fires again once the last fire is older than the most recent occurrence" do
    zone = "Australia/Sydney"
    workflow = submit!(zone)

    set_field(workflow, :state_entered_at, DateTime.add(last_occurrence(zone), -8, :day))
    set_field(workflow, :waiting_digest_last_fired_at, before_occurrence(zone))

    run_trigger!()
    drain!()

    assert digest_count(workflow) == 1
  end

  test "a missed occurrence fires once, late, rather than once per occurrence missed" do
    zone = "Australia/Sydney"
    workflow = submit!(zone)

    set_field(workflow, :state_entered_at, DateTime.add(last_occurrence(zone), -30, :day))

    set_field(
      workflow,
      :waiting_digest_last_fired_at,
      DateTime.add(last_occurrence(zone), -7, :day)
    )

    run_trigger!()
    drain!()

    assert digest_count(workflow) == 1
  end

  test "does not fire before the occurrence has arrived in the record's own zone" do
    zone = "Australia/Sydney"
    workflow = submit!(zone)

    # Entered after the most recent occurrence, so the next one is still ahead.
    set_field(workflow, :state_entered_at, DateTime.add(last_occurrence(zone), 1, :minute))

    run_trigger!()
    drain!()

    assert digest_count(workflow) == 0
  end

  test "two records in different zones are not both due at the same instant" do
    sydney_zone = "Australia/Sydney"
    london_zone = "Europe/London"

    sydney = submit!(sydney_zone)
    london = submit!(london_zone)

    # Each record entered just after its own most recent occurrence, so
    # neither is due. Then only Sydney is pushed back before its occurrence.
    set_field(sydney, :state_entered_at, DateTime.add(last_occurrence(sydney_zone), 1, :minute))
    set_field(london, :state_entered_at, DateTime.add(last_occurrence(london_zone), 1, :minute))

    run_trigger!()
    drain!()

    assert digest_count(sydney) == 0
    assert digest_count(london) == 0

    set_field(sydney, :state_entered_at, before_occurrence(sydney_zone))

    run_trigger!()
    drain!()

    assert digest_count(sydney) == 1
    assert digest_count(london) == 0
  end

  test "the fragment agrees with AshWorkflow.WallClock about which records are due" do
    zone = "Australia/Sydney"
    due = submit!(zone)
    not_due = submit!(zone)

    set_field(due, :state_entered_at, before_occurrence(zone))
    set_field(not_due, :state_entered_at, DateTime.add(last_occurrence(zone), 1, :minute))

    [work] =
      Workflow
      |> AshWorkflow.Info.scheduled_work()
      |> Enum.filter(&(&1.timeout == :digest))

    matched =
      Workflow
      |> Ash.Query.do_filter(work.match)
      |> Ash.read!(authorize?: false, page: false)
      |> Enum.map(& &1.id)

    assert due.id in matched
    refute not_due.id in matched
  end
end
