defmodule AshWorkflow.Scheduler.WallClockEveryTest do
  @moduledoc """
  `every ... at` fired through `AshWorkflow.Scheduler.Precise`.

  `AshWorkflowTest.WallClockWorkflow` sends a digest at 09:00 on weekdays in
  the zone `candidate_time_zone` holds. These tests move `state_entered_at`
  and `digest_fired_at` around the occurrence rather than waiting for a real
  09:00, and drive the firing with `Precise.run_due/2`.

  The interesting case is the last one: two records in the same step, in
  different zones, are due at different instants. That is what a global cron
  cannot express, and it is why `time_zone` reads an attribute.
  """
  use ExUnit.Case, async: false

  alias Ash.DataLayer.Ets
  alias AshWorkflow.Scheduler.Precise
  alias AshWorkflowTest.WallClockWorkflow, as: Workflow

  @table_manager Module.concat(Workflow, Ash.DataLayer.Ets.TableManager)

  setup do
    on_exit(fn ->
      Ets.stop(Workflow)
      await_stopped(@table_manager)
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

  defp create!(zone), do: Workflow.create!(%{title: "one", candidate_time_zone: zone})

  defp set_clock(record, fields) do
    Enum.reduce(fields, Ash.Changeset.for_update(record, :set_clock, %{}), fn {field, value},
                                                                              changeset ->
      Ash.Changeset.force_change_attribute(changeset, field, value)
    end)
    |> Ash.update!()
  end

  defp reload(record), do: Ash.get!(Workflow, record.id)

  defp digest_count(record), do: reload(record).digest_count

  # The most recent 09:00 in the record's zone, as an instant. Putting
  # `state_entered_at` before it makes the record due now; putting it after
  # makes it not.
  defp last_occurrence(zone) do
    {:ok, days} = AshWorkflow.WallClock.to_day_numbers([:mon, :tue, :wed, :thu, :fri])

    AshWorkflow.WallClock.previous_occurrence(
      %AshWorkflow.WallClock{time: ~T[09:00:00], days: days, time_zone: zone},
      zone,
      DateTime.utc_now()
    )
  end

  test "does not fire on entry, even when today's occurrence has already passed" do
    record = create!("Australia/Sydney")

    assert Precise.run_due(Workflow) == 0
    assert digest_count(record) == 0
  end

  test "fires once the record entered the step before the most recent occurrence" do
    zone = "Australia/Sydney"
    record = create!(zone)

    set_clock(record, state_entered_at: DateTime.add(last_occurrence(zone), -1, :hour))

    assert Precise.run_due(Workflow) == 1
    assert digest_count(record) == 1
  end

  test "writes the last-fired column rather than moving state_entered_at" do
    zone = "Australia/Sydney"
    record = create!(zone)
    entered_at = DateTime.add(last_occurrence(zone), -1, :hour)

    set_clock(record, state_entered_at: entered_at)
    assert Precise.run_due(Workflow) == 1

    reloaded = Ash.load!(reload(record), :digest_fired_at)

    assert DateTime.compare(reloaded.state_entered_at, entered_at) == :eq
    assert reloaded.digest_fired_at
  end

  test "does not fire twice for one occurrence" do
    zone = "Australia/Sydney"
    record = create!(zone)

    set_clock(record, state_entered_at: DateTime.add(last_occurrence(zone), -1, :hour))

    assert Precise.run_due(Workflow) == 1
    assert Precise.run_due(Workflow) == 0
    assert digest_count(record) == 1
  end

  test "fires again once the last fire is older than the most recent occurrence" do
    zone = "Australia/Sydney"
    record = create!(zone)

    set_clock(record,
      state_entered_at: DateTime.add(last_occurrence(zone), -8, :day),
      digest_fired_at: DateTime.add(last_occurrence(zone), -1, :hour)
    )

    assert Precise.run_due(Workflow) == 1
    assert digest_count(record) == 1
  end

  test "a missed occurrence still fires, late" do
    zone = "Australia/Sydney"
    record = create!(zone)

    # Nothing polled for a week, so the last fire is far behind the most
    # recent occurrence. It fires once, not once per missed occurrence.
    set_clock(record,
      state_entered_at: DateTime.add(last_occurrence(zone), -30, :day),
      digest_fired_at: DateTime.add(last_occurrence(zone), -7, :day)
    )

    assert Precise.run_due(Workflow) == 1
    assert digest_count(record) == 1
    assert Precise.run_due(Workflow) == 0
  end

  test "reports the next occurrence on pending_deadlines" do
    zone = "Australia/Sydney"
    record = create!(zone)

    [deadline] = Ash.load!(reload(record), :pending_deadlines).pending_deadlines

    assert deadline.name == :digest
    assert deadline.kind == :every

    local = DateTime.shift_zone!(deadline.due_at, zone)
    assert DateTime.to_time(local) == ~T[09:00:00]
    assert Date.day_of_week(DateTime.to_date(local)) in 1..5
  end

  test "two records in different zones are due at different instants" do
    sydney = create!("Australia/Sydney")
    london = create!("Europe/London")

    [sydney_deadline] = Ash.load!(reload(sydney), :pending_deadlines).pending_deadlines
    [london_deadline] = Ash.load!(reload(london), :pending_deadlines).pending_deadlines

    refute DateTime.compare(sydney_deadline.due_at, london_deadline.due_at) == :eq
  end

  test "a record whose zone the time zone database does not know fires nothing" do
    record = create!("Mars/Olympus_Mons")

    set_clock(record, state_entered_at: DateTime.add(DateTime.utc_now(), -30, :day))

    assert Precise.run_due(Workflow) == 0
    assert digest_count(record) == 0
    assert Ash.load!(reload(record), :pending_deadlines).pending_deadlines == []
  end
end
