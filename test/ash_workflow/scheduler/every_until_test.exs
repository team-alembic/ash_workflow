defmodule AshWorkflow.Scheduler.EveryUntilTest do
  @moduledoc """
  `until` bounds an `every` by wall-clock time since the record entered the
  step, measured against `state_entered_at`. `AshWorkflowTest.EveryUntilWorkflow`
  reminds every hour and stops after 3 hours, so these tests age
  `state_entered_at` and drive the firing with
  `AshWorkflow.Scheduler.Precise.run_due/2` so no real clock has to pass.
  """
  use ExUnit.Case, async: false

  alias Ash.DataLayer.Ets
  alias AshWorkflow.Scheduler.Precise
  alias AshWorkflowTest.EveryUntilWorkflow, as: Workflow

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

  defp age_state_entered_at(record, hours) do
    record
    |> Ash.Changeset.for_update(:set_clock, %{})
    |> Ash.Changeset.force_change_attribute(:state_entered_at, ago(hours, :hour))
    |> Ash.update!()
  end

  defp reload(record), do: Ash.get!(Workflow, record.id)

  test "entering the step sets state_entered_at" do
    record = create!()

    assert record.reminder_count == 0

    # Loaded fresh from the data layer, since `Ash.Changeset.for_create/3`
    # does not select non-accepted fields.
    reloaded = reload(record)
    refute is_nil(reloaded.state_entered_at)
  end

  test "firing writes the explicit last_fired_field, not a generated default name" do
    record = create!()
    refute Ash.load!(record, :reminder_fired_at).reminder_fired_at

    assert Precise.run_due(Workflow) == 1

    reloaded = Ash.load!(reload(record), :reminder_fired_at)
    assert reloaded.reminder_fired_at
  end

  test "fires on schedule while under the bound, leaving state_entered_at where it was" do
    record = create!() |> age_state_entered_at(1)

    assert Precise.run_due(Workflow) == 1

    reloaded = reload(record)
    assert reloaded.reminder_count == 1
    assert reloaded.state == :waiting

    # Firing wrote the every's own last-fired column, not state_entered_at, so
    # the anchor `until` measures against is still where it was set.
    assert DateTime.diff(reloaded.state_entered_at, ago(1, :hour), :second) in -5..5
  end

  test "stops matching once state_entered_at is past the bound, even though interval has elapsed" do
    record = create!() |> age_state_entered_at(4)

    assert Precise.run_due(Workflow) == 0

    reloaded = reload(record)
    assert reloaded.reminder_count == 0
    assert reloaded.state == :waiting
  end

  test "a record that has never fired is treated as due" do
    record = create!() |> age_state_entered_at(1)

    assert Precise.run_due(Workflow) == 1
    assert reload(record).reminder_count == 1
  end

  test "firing again after the interval elapses does not reopen the bound" do
    record = create!() |> age_state_entered_at(1)

    assert Precise.run_due(Workflow) == 1
    assert reload(record).reminder_count == 1

    aged_again = record |> reload() |> age_state_entered_at(4)
    assert Precise.run_due(Workflow) == 0
    assert reload(aged_again).reminder_count == 1
  end
end
