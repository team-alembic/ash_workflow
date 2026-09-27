defmodule AshWorkflow.Scheduler.StrideEveryTest do
  @moduledoc """
  `interval` combined with `at`: `on` picks which days are occurrences, the
  interval picks every Nth of them.

  `AshWorkflowTest.StrideWorkflow` digests at 09:00 on Mondays, fourteen local
  days apart. The case worth pinning is the one a duration comparison gets
  wrong: a last fire a microsecond after 09:00 must not push the occurrence
  exactly fourteen days later out to the following week.
  """
  use ExUnit.Case, async: false

  alias Ash.DataLayer.Ets
  alias AshWorkflow.Scheduler.Precise
  alias AshWorkflow.WallClock
  alias AshWorkflowTest.StrideWorkflow, as: Workflow

  @zone "Australia/Sydney"
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

  defp schedule, do: %WallClock{time: ~T[09:00:00], days: [1], time_zone: @zone, stride: 14}

  defp create!, do: Workflow.create!(%{title: "one", candidate_time_zone: @zone})

  defp set_clock(record, fields) do
    Enum.reduce(fields, Ash.Changeset.for_update(record, :set_clock, %{}), fn {field, value},
                                                                              changeset ->
      Ash.Changeset.force_change_attribute(changeset, field, value)
    end)
    |> Ash.update!()
  end

  defp reload(record), do: Ash.get!(Workflow, record.id)

  defp digest_count(record), do: reload(record).digest_count

  # The most recent Monday 09:00 in the zone, as an instant.
  defp last_monday do
    WallClock.previous_occurrence(
      %WallClock{schedule() | stride: nil},
      @zone,
      DateTime.utc_now()
    )
  end

  test "a Monday inside the stride is not an occurrence to fire on" do
    record = create!()

    # Fired last Monday. This Monday is seven local days later, half a stride.
    set_clock(record,
      state_entered_at: DateTime.add(last_monday(), -60, :day),
      digest_fired_at: DateTime.add(last_monday(), -7, :day)
    )

    assert Precise.run_due(Workflow) == 0
    assert digest_count(record) == 0
  end

  test "a Monday a full stride after the last fire does fire" do
    record = create!()

    set_clock(record,
      state_entered_at: DateTime.add(last_monday(), -60, :day),
      digest_fired_at: DateTime.add(last_monday(), -14, :day)
    )

    assert Precise.run_due(Workflow) == 1
    assert digest_count(record) == 1
  end

  test "a last fire a moment after 09:00 does not push the occurrence out a week" do
    record = create!()

    # This is what firing actually writes: the column lands microseconds after
    # the occurrence it fired for. Measured as a duration, `last_fire + 14
    # days` falls after the Monday exactly fourteen days later, and the digest
    # would slip to the Monday after that. Measured as local dates, it does
    # not.
    fired_at =
      last_monday()
      |> DateTime.add(-14, :day)
      |> DateTime.add(1, :microsecond)

    set_clock(record,
      state_entered_at: DateTime.add(last_monday(), -60, :day),
      digest_fired_at: fired_at
    )

    assert Precise.run_due(Workflow) == 1
    assert digest_count(record) == 1
  end

  test "the first fire is one whole stride after entry, since there is no last fire" do
    record = create!()

    set_clock(record, state_entered_at: DateTime.add(last_monday(), -7, :day))

    assert Precise.run_due(Workflow) == 0

    set_clock(record, state_entered_at: DateTime.add(last_monday(), -14, :day))

    assert Precise.run_due(Workflow) == 1
    assert digest_count(record) == 1
  end

  test "pending_deadlines reports a Monday a stride out, not the next Monday" do
    record = create!()
    fired_at = DateTime.add(last_monday(), -14, :day)

    set_clock(record, state_entered_at: DateTime.add(last_monday(), -60, :day))
    record = set_clock(record, digest_fired_at: fired_at)

    [deadline] = Ash.load!(reload(record), :pending_deadlines).pending_deadlines

    local = DateTime.shift_zone!(deadline.due_at, @zone)
    local_fired = DateTime.shift_zone!(fired_at, @zone)

    assert Date.day_of_week(DateTime.to_date(local)) == 1
    assert DateTime.to_time(local) == ~T[09:00:00]

    assert Date.diff(DateTime.to_date(local), DateTime.to_date(local_fired)) == 14
  end
end
