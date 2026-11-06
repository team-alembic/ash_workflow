defmodule AshWorkflowTest.Postgres.StrideObanTest do
  @moduledoc """
  `interval` combined with `at`, against a real database and a real Oban
  trigger.

  The stride reaches the trigger's `where` clause as a `date - date`
  comparison in the record's own zone, not as a duration. The third test is
  the one that distinguishes the two: a last fire a microsecond after 09:00
  would fail a duration comparison at the occurrence exactly fourteen days
  later, and slip the digest a week.
  """
  use AshWorkflowTest.DataCase

  alias AshWorkflow.WallClock
  alias AshWorkflowTest.Postgres.StrideWorkflow, as: Workflow

  @zone "Australia/Sydney"

  defp submit!, do: Workflow.submit!(%{title: "one", candidate_time_zone: @zone})

  defp run_trigger! do
    AshOban.schedule_and_run_triggers({Workflow, :__every_trigger_waiting_digest})
  end

  defp drain! do
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)
  end

  defp digest_count(record), do: Ash.get!(Workflow, record.id, authorize?: false).digest_count

  defp last_monday do
    WallClock.previous_occurrence(
      %WallClock{time: ~T[09:00:00], days: [1], time_zone: @zone},
      @zone,
      DateTime.utc_now()
    )
  end

  defp entered_long_ago(workflow) do
    set_field(workflow, :state_entered_at, DateTime.add(last_monday(), -60, :day))
  end

  test "a Monday inside the stride is not an occurrence to fire on" do
    workflow = submit!()

    entered_long_ago(workflow)
    set_field(workflow, :waiting_digest_last_fired_at, DateTime.add(last_monday(), -7, :day))

    run_trigger!()
    drain!()

    assert digest_count(workflow) == 0
  end

  test "a Monday a full stride after the last fire does fire" do
    workflow = submit!()

    entered_long_ago(workflow)
    set_field(workflow, :waiting_digest_last_fired_at, DateTime.add(last_monday(), -14, :day))

    run_trigger!()
    drain!()

    assert digest_count(workflow) == 1
  end

  test "a last fire a moment after 09:00 does not push the occurrence out a week" do
    workflow = submit!()

    fired_at =
      last_monday()
      |> DateTime.add(-14, :day)
      |> DateTime.add(1, :microsecond)

    entered_long_ago(workflow)
    set_field(workflow, :waiting_digest_last_fired_at, fired_at)

    run_trigger!()
    drain!()

    assert digest_count(workflow) == 1,
           "the stride counts local dates, so microseconds past 09:00 cannot skip an occurrence"
  end

  test "the first fire is one whole stride after entry, since there is no last fire" do
    workflow = submit!()

    set_field(workflow, :state_entered_at, DateTime.add(last_monday(), -7, :day))

    run_trigger!()
    drain!()

    assert digest_count(workflow) == 0

    set_field(workflow, :state_entered_at, DateTime.add(last_monday(), -14, :day))

    run_trigger!()
    drain!()

    assert digest_count(workflow) == 1
  end

  test "the fragment agrees with AshWorkflow.WallClock about which records are due" do
    due = submit!()
    inside_stride = submit!()

    entered_long_ago(due)
    set_field(due, :waiting_digest_last_fired_at, DateTime.add(last_monday(), -14, :day))

    entered_long_ago(inside_stride)
    set_field(inside_stride, :waiting_digest_last_fired_at, DateTime.add(last_monday(), -7, :day))

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
    refute inside_stride.id in matched
  end
end
