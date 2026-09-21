defmodule AshWorkflow.Scheduler.EveryCollisionTest do
  @moduledoc """
  Characterises what two `every` entities and a `fire_after` timeout do to each
  other when they share a step.

  All three measure against `state_entered_at`, and firing an `every` resets it
  so the next interval can be armed. `AshWorkflowTest.MultiEveryWorkflow`
  reminds hourly, digests every two hours and escalates after five, so these
  tests age `state_entered_at` and drive the sweep with
  `AshWorkflow.Scheduler.Precise.run_due/2`.
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

  defp age(record, hours) do
    record
    |> Ash.Changeset.for_update(:set_clock, %{})
    |> Ash.Changeset.force_change_attribute(:state_entered_at, ago(hours))
    |> Ash.update!()
  end

  test "only the first every fires when both are due in the same sweep" do
    record = create!() |> age(2)

    # Both are due at two hours: :reminder against its one-hour interval and
    # :digest against its two. `Timeline.run_due/2` reads records per work
    # item, so :reminder fires first and resets `state_entered_at`, and
    # :digest's read then matches nothing.
    assert Precise.run_due(Workflow) == 1

    reloaded = reload(record)
    assert reloaded.reminder_count == 1
    assert reloaded.digest_count == 0

    # And a second sweep does not catch it up: the anchor is now "just now".
    assert Precise.run_due(Workflow) == 0
    assert reload(record).digest_count == 0
  end

  test "the faster every starves the slower one: digest never fires on its own interval" do
    record = create!() |> age(1)

    # Hour 1: only :reminder is due. Firing it resets state_entered_at, which
    # is also the anchor :digest measures its two hours from.
    Precise.run_due(Workflow)
    assert reload(record).reminder_count == 1
    assert reload(record).digest_count == 0

    # Another hour passes. :reminder is due again against the anchor it just
    # reset; :digest is one hour old again rather than two, so it is not.
    record |> reload() |> age(1)
    Precise.run_due(Workflow)

    reloaded = reload(record)
    assert reloaded.reminder_count == 2
    assert reloaded.digest_count == 0
  end

  test "an every starves a transition_to timeout on the same step" do
    record = create!() |> age(4)

    # Hour 4: :escalation needs five, so only the everys fire — and they reset
    # the anchor :escalation measures from.
    Precise.run_due(Workflow)
    assert reload(record).state == :waiting

    # Six hours after the record genuinely entered the step, escalation is
    # still four hours short, because the anchor moved under it.
    record |> reload() |> age(2)
    Precise.run_due(Workflow)

    assert reload(record).state == :waiting
  end
end
