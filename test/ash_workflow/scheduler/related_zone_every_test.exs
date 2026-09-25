defmodule AshWorkflow.Scheduler.RelatedZoneEveryTest do
  @moduledoc """
  `time_zone` naming an expression calculation rather than a column.

  `AshWorkflowTest.RelatedZoneWorkflow` reads its zone off a related
  `AshWorkflowTest.Candidate` through
  `calculate :candidate_time_zone, :string, expr(candidate.time_zone)`. The
  calculation does the reaching, so `time_zone` stays one name.

  The thing worth pinning is that the readers load it. `AshWorkflow.Scheduler`
  reads the zone off the record with `Map.get/2`, which finds nothing for a
  calculation nobody asked for, so a missing load would silently arm no timer
  rather than fail loudly.
  """
  use ExUnit.Case, async: false

  alias Ash.DataLayer.Ets
  alias AshWorkflow.Scheduler.Precise
  alias AshWorkflow.WallClock
  alias AshWorkflowTest.Candidate
  alias AshWorkflowTest.RelatedZoneWorkflow, as: Workflow

  @table_manager Module.concat(Workflow, Ash.DataLayer.Ets.TableManager)
  @candidate_table_manager Module.concat(Candidate, Ash.DataLayer.Ets.TableManager)

  setup do
    on_exit(fn ->
      Ets.stop(Workflow)
      Ets.stop(Candidate)
      await_stopped(@table_manager)
      await_stopped(@candidate_table_manager)
    end)

    :ok
  end

  defp await_stopped(name, tries \\ 200) do
    cond do
      is_nil(Process.whereis(name)) -> :ok
      tries == 0 -> raise "#{inspect(name)} did not stop"
      true -> Process.sleep(5) && await_stopped(name, tries - 1)
    end
  end

  defp create!(zone) do
    candidate = Candidate.create!(%{name: "one", time_zone: zone})

    Workflow.create!(%{title: "one", candidate_id: candidate.id})
  end

  defp set_clock(record, fields) do
    Enum.reduce(fields, Ash.Changeset.for_update(record, :set_clock, %{}), fn {field, value},
                                                                              changeset ->
      Ash.Changeset.force_change_attribute(changeset, field, value)
    end)
    |> Ash.update!()
  end

  defp reload(record), do: Ash.get!(Workflow, record.id)

  defp digest_count(record), do: reload(record).digest_count

  defp last_occurrence(zone) do
    {:ok, days} = WallClock.to_day_numbers(WallClock.day_names())

    WallClock.previous_occurrence(
      %WallClock{time: ~T[09:00:00], days: days, time_zone: zone},
      zone,
      DateTime.utc_now()
    )
  end

  test "the calculation resolves, so the every fires on the related record's zone" do
    zone = "Australia/Sydney"
    record = create!(zone)

    set_clock(record, state_entered_at: DateTime.add(last_occurrence(zone), -1, :hour))

    assert Precise.run_due(Workflow) == 1
    assert digest_count(record) == 1
  end

  test "does not fire before the occurrence has arrived in the related record's zone" do
    zone = "Australia/Sydney"
    record = create!(zone)

    set_clock(record, state_entered_at: DateTime.add(last_occurrence(zone), 1, :minute))

    assert Precise.run_due(Workflow) == 0
    assert digest_count(record) == 0
  end

  test "two workflows whose candidates are in different zones are due at different instants" do
    sydney = create!("Australia/Sydney")
    london = create!("Europe/London")

    [sydney_deadline] = Ash.load!(reload(sydney), :pending_deadlines).pending_deadlines
    [london_deadline] = Ash.load!(reload(london), :pending_deadlines).pending_deadlines

    refute DateTime.compare(sydney_deadline.due_at, london_deadline.due_at) == :eq
  end

  test "pending_deadlines loads the calculation rather than reporting nothing" do
    record = create!("Europe/London")

    [deadline] = Ash.load!(reload(record), :pending_deadlines).pending_deadlines

    assert deadline.name == :digest

    local = DateTime.shift_zone!(deadline.due_at, "Europe/London")
    assert DateTime.to_time(local) == ~T[09:00:00]
  end
end
