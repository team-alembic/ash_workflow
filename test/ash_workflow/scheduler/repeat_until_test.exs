defmodule AshWorkflow.Scheduler.RepeatUntilTest do
  @moduledoc """
  `repeat_until` bounds a repeating timeout by wall-clock time since the record
  entered the step, not since the timeout last fired. `AshWorkflowTest.RepeatUntilWorkflow`
  reminds every hour and stops after 3 hours, so these tests age
  `state_entered_at` (the anchor `repeat` keeps pushing forward) and
  `repeat_started_at` (the fixed anchor `repeat_until` measures against)
  independently, and drive the timeout with `AshWorkflow.Scheduler.Precise.run_due/2`
  so no real clock has to pass.
  """
  use ExUnit.Case, async: false

  alias Ash.DataLayer.Ets
  alias AshWorkflow.Scheduler.Precise
  alias AshWorkflowTest.RepeatUntilWorkflow, as: Workflow

  @table_manager Module.concat(Workflow, Ash.DataLayer.Ets.TableManager)

  # The Ets table backing this resource is process-global rather than
  # per-test, so a record left behind by one test would still match the next
  # one's `Precise.run_due/2` sweep. See `AshWorkflow.Scheduler.PreciseTest`
  # for the same pattern and why it waits for the manager to actually stop.
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

  defp create!, do: Workflow.create!(%{title: "one"})

  defp ago(amount, :hour), do: DateTime.add(DateTime.utc_now(), -amount, :hour)

  defp set_clock(record, attrs) do
    record
    |> Ash.Changeset.for_update(:set_clock, attrs)
    |> Ash.update!()
  end

  defp reload(record), do: Ash.get!(Workflow, record.id)

  test "entering the step sets repeat_started_at alongside state_entered_at" do
    record = create!()

    assert record.reminder_count == 0

    # Both attributes come from the resource, loaded fresh from the data layer,
    # since `Ash.Changeset.for_create/3` does not select non-accepted fields.
    reloaded = reload(record)
    refute is_nil(reloaded.state_entered_at)
  end

  test "fires on schedule while under the bound, resetting state_entered_at but not repeat_started_at" do
    record = create!()

    aged =
      set_clock(record, %{
        state_entered_at: ago(1, :hour),
        repeat_started_at: ago(1, :hour)
      })

    assert Precise.run_due(Workflow) == 1

    reloaded = reload(aged)
    assert reloaded.reminder_count == 1
    assert reloaded.state == :waiting

    # The repeat reset state_entered_at to re-arm the next hour, but left
    # repeat_started_at where it was — otherwise the bound could never be
    # reached, since repeating is exactly what keeps moving state_entered_at.
    assert DateTime.diff(reloaded.state_entered_at, DateTime.utc_now(), :second) > -5
  end

  test "stops matching once repeat_started_at is past the bound, even though fire_after has elapsed" do
    record = create!()

    set_clock(record, %{
      state_entered_at: ago(1, :hour),
      repeat_started_at: ago(4, :hour)
    })

    assert Precise.run_due(Workflow) == 0

    reloaded = reload(record)
    assert reloaded.reminder_count == 0
    assert reloaded.state == :waiting
  end

  test "a record with no repeat_started_at (pre-existing data) is treated as bound-not-reached" do
    record = create!()

    aged =
      record
      |> Ash.Changeset.for_update(:set_clock, %{state_entered_at: ago(1, :hour)})
      |> Ash.Changeset.force_change_attribute(:repeat_started_at, nil)
      |> Ash.update!()

    assert Precise.run_due(Workflow) == 1

    reloaded = reload(aged)
    assert reloaded.reminder_count == 1
  end

  test "a repeat fire backfills a nil repeat_started_at from the pre-firing state_entered_at, once" do
    record = create!()
    stale_entry = ago(1, :hour)

    aged =
      record
      |> Ash.Changeset.for_update(:set_clock, %{state_entered_at: stale_entry})
      |> Ash.Changeset.force_change_attribute(:repeat_started_at, nil)
      |> Ash.update!()

    assert Precise.run_due(Workflow) == 1

    once_backfilled = reload(aged)
    assert DateTime.compare(once_backfilled.repeat_started_at, stale_entry) == :eq

    # A second fire, further within the bound the backfilled anchor now
    # implies, must not move repeat_started_at again — only the first repeat
    # after the attribute was unset backfills it.
    set_clock(once_backfilled, %{state_entered_at: ago(1, :hour)})
    assert Precise.run_due(Workflow) == 1

    twice_fired = reload(once_backfilled)
    assert twice_fired.reminder_count == 2
    assert DateTime.compare(twice_fired.repeat_started_at, stale_entry) == :eq
  end
end
