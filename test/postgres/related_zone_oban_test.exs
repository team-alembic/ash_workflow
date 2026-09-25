defmodule AshWorkflowTest.Postgres.RelatedZoneObanTest do
  @moduledoc """
  A wall-clock `every` whose zone comes from a related record, against a real
  database and a real Oban trigger.

  `time_zone` names `calculate :candidate_time_zone, :string,
  expr(candidate.time_zone)`, so the trigger's `where` clause has to inline
  that calculation and join to `candidates` before it can shift `now()` into
  the zone. Nothing here can be checked on Ets, and it is the reason
  `AshWorkflow.Verifiers.ValidateEvery` rejects a module calculation for
  `time_zone`.
  """
  use AshWorkflowTest.DataCase

  alias AshWorkflow.WallClock
  alias AshWorkflowTest.Postgres.Candidate
  alias AshWorkflowTest.Postgres.RelatedZoneWorkflow, as: Workflow

  defp submit!(zone) do
    candidate = Candidate.create!(%{name: "one", time_zone: zone})

    Workflow.submit!(%{title: "one", candidate_id: candidate.id})
  end

  defp run_trigger! do
    AshOban.schedule_and_run_triggers({Workflow, :__every_trigger_waiting_digest})
  end

  defp drain! do
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)
  end

  defp digest_count(record), do: Ash.get!(Workflow, record.id, authorize?: false).digest_count

  defp last_occurrence(zone) do
    {:ok, days} = WallClock.to_day_numbers(WallClock.day_names())

    WallClock.previous_occurrence(
      %WallClock{time: ~T[09:00:00], days: days, time_zone: zone},
      zone,
      DateTime.utc_now()
    )
  end

  test "the trigger reads the zone through the relationship and fires" do
    zone = "Australia/Sydney"
    workflow = submit!(zone)

    set_field(workflow, :state_entered_at, DateTime.add(last_occurrence(zone), -1, :hour))

    run_trigger!()
    drain!()

    assert digest_count(workflow) == 1
  end

  test "does not fire before the occurrence has arrived in the related record's zone" do
    zone = "Australia/Sydney"
    workflow = submit!(zone)

    set_field(workflow, :state_entered_at, DateTime.add(last_occurrence(zone), 1, :minute))

    run_trigger!()
    drain!()

    assert digest_count(workflow) == 0
  end

  test "two workflows whose candidates are in different zones are due at different instants" do
    sydney_zone = "Australia/Sydney"
    london_zone = "Europe/London"

    sydney = submit!(sydney_zone)
    london = submit!(london_zone)

    set_field(sydney, :state_entered_at, DateTime.add(last_occurrence(sydney_zone), 1, :minute))
    set_field(london, :state_entered_at, DateTime.add(last_occurrence(london_zone), 1, :minute))

    run_trigger!()
    drain!()

    assert digest_count(sydney) == 0
    assert digest_count(london) == 0

    set_field(sydney, :state_entered_at, DateTime.add(last_occurrence(sydney_zone), -1, :hour))

    run_trigger!()
    drain!()

    assert digest_count(sydney) == 1
    assert digest_count(london) == 0
  end

  test "the calculation inlines into the trigger filter rather than failing the query" do
    zone = "Australia/Sydney"
    due = submit!(zone)
    not_due = submit!(zone)

    set_field(due, :state_entered_at, DateTime.add(last_occurrence(zone), -1, :hour))
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
