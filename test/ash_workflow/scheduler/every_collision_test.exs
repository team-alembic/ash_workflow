defmodule AshWorkflow.Scheduler.EveryCollisionTest do
  @moduledoc """
  Two `every` entities and a `fire_after` timeout sharing one step, each
  measuring against its own last-fired column rather than sharing (and
  resetting) one anchor. `AshWorkflowTest.MultiEveryWorkflow` reminds hourly,
  digests every two hours and escalates after five, so these tests age
  `state_entered_at` and each `every`'s own column independently, and drive
  the sweep with `AshWorkflow.Scheduler.Precise.run_due/2`.
  """
  use ExUnit.Case, async: false

  alias Ash.DataLayer.Ets
  alias AshWorkflow.Scheduler.Precise
  alias AshWorkflowTest.MultiEveryWorkflow, as: Workflow

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

  defp create!, do: Workflow.create!(%{title: "one"})
  defp ago(amount), do: DateTime.add(DateTime.utc_now(), -amount, :hour)
  defp reload(record), do: Ash.get!(Workflow, record.id)

  defp age(record, field, hours) do
    record
    |> Ash.Changeset.for_update(:set_clock, %{})
    |> Ash.Changeset.force_change_attribute(field, ago(hours))
    |> Ash.update!()
  end

  # Both everys have never fired on a fresh record, and a nil column is due
  # rather than waiting for a column only firing itself would write. Forcing
  # both to "just fired" first is what lets the rest of these tests control
  # each every's own schedule independently of that initial-fire behaviour.
  defp mark_fired_now(record) do
    record
    |> age(:waiting_reminder_last_fired_at, 0)
    |> age(:waiting_digest_last_fired_at, 0)
  end

  test "a never-fired record fires every every immediately, regardless of interval" do
    record = create!()

    assert Precise.run_due(Workflow) == 2

    reloaded = reload(record)
    assert reloaded.reminder_count == 1
    assert reloaded.digest_count == 1
  end

  test "both everys fire independently when both are due in the same sweep" do
    record =
      create!()
      |> mark_fired_now()
      |> age(:waiting_reminder_last_fired_at, 1)
      |> age(:waiting_digest_last_fired_at, 2)

    # :reminder is due against its one-hour interval and :digest against its
    # two. Each measures its own last-fired column, so :reminder firing does
    # not starve :digest's read in the same sweep.
    assert Precise.run_due(Workflow) == 2

    reloaded = reload(record)
    assert reloaded.reminder_count == 1
    assert reloaded.digest_count == 1

    # And a second sweep does not catch them up again: each every's own
    # column was just written, so neither is due until its interval elapses
    # again.
    assert Precise.run_due(Workflow) == 0
  end

  test "the faster every does not starve the slower one: digest fires on its own interval" do
    record =
      create!()
      |> mark_fired_now()
      |> age(:waiting_reminder_last_fired_at, 1)

    # :reminder is due; :digest, still "just fired", is not.
    Precise.run_due(Workflow)
    assert reload(record).reminder_count == 1
    assert reload(record).digest_count == 0

    # :digest becomes due on its own schedule, independent of how many times
    # :reminder has fired in the meantime.
    record |> reload() |> age(:waiting_digest_last_fired_at, 2)
    Precise.run_due(Workflow)

    assert reload(record).digest_count == 1
  end

  test "an every does not starve a transition_to timeout on the same step" do
    record =
      create!()
      |> mark_fired_now()
      |> age(:waiting_reminder_last_fired_at, 1)
      |> age(:state_entered_at, 4)

    entered_at = reload(record).state_entered_at

    # Hour 4: :reminder is due against its one-hour interval and fires;
    # :digest, still "just fired", is not; :escalation needs five hours, so
    # it is not yet due either.
    assert Precise.run_due(Workflow) == 1

    reloaded = reload(record)
    assert reloaded.reminder_count == 1
    assert reloaded.state == :waiting

    # The fire did not move state_entered_at — the anchor escalation measures
    # from is exactly where ageing left it, not reset by the every firing.
    assert DateTime.compare(reloaded.state_entered_at, entered_at) == :eq

    # Six hours after the record genuinely entered the step, escalation has
    # had its five hours and fires.
    record |> reload() |> age(:state_entered_at, 6)
    Precise.run_due(Workflow)

    assert reload(record).state == :escalated
  end
end
