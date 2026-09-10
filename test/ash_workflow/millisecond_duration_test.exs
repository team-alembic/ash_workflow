defmodule AshWorkflow.MillisecondDurationTest do
  @moduledoc """
  `after` takes a duration in milliseconds, for deadlines a cron interval cannot
  express at all.

  The unit is decoded in five places: `AshWorkflow.Entities.Timeout` validates
  it, `AshWorkflow.Transformers.AddScheduler` turns it into the `ago/2` call in
  a work's `match`, `AshWorkflow.Scheduler.due_at/2` and
  `AshWorkflow.Scheduler.Precise.Timeline` compute the instant a timer fires at,
  and `AshWorkflow.Calculations.PendingDeadlines` reports it. These tests walk
  that path rather than only asserting the DSL compiles.
  """
  use ExUnit.Case, async: false

  alias Ash.DataLayer.Ets
  alias AshWorkflow.Entities.Timeout
  alias AshWorkflow.Info
  alias AshWorkflow.Scheduler
  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.MillisecondTimeoutWorkflow

  @resource MillisecondTimeoutWorkflow
  @table_manager Module.concat(MillisecondTimeoutWorkflow, Ash.DataLayer.Ets.TableManager)

  setup do
    on_exit(&reset_storage/0)

    :ok
  end

  defp reset_storage do
    Ets.stop(@resource)

    await_stopped(@table_manager)
  end

  defp await_stopped(name, tries \\ 200) do
    cond do
      is_nil(Process.whereis(name)) -> :ok
      tries == 0 -> raise "#{inspect(name)} did not stop"
      true -> Process.sleep(5) && await_stopped(name, tries - 1)
    end
  end

  defp record(deadline_from) do
    @resource
    |> Ash.Changeset.for_create(:create, %{title: "one", deadline_from: deadline_from})
    |> Ash.create!()
  end

  defp ago(ms), do: DateTime.add(DateTime.utc_now(), -ms, :millisecond)

  defp nudge do
    @resource
    |> Info.scheduled_work()
    |> Enum.find(&(&1.timeout == :nudge))
  end

  describe "the entity" do
    test "accepts a duration in milliseconds" do
      timeout =
        @resource
        |> Info.steps()
        |> Enum.find(&(&1.name == :waiting))
        |> Map.fetch!(:timeouts)
        |> Enum.find(&(&1.name == :nudge))

      assert timeout.after == {250, :milliseconds}
    end

    test "rejects a unit it does not know" do
      assert {:error, message} = Timeout.validate_duration({250, :fortnights}, [:milliseconds])

      assert message =~ ":fortnights"
    end

    test "rejects milliseconds where the caller does not permit them" do
      assert {:error, message} = Timeout.validate_duration({250, :milliseconds}, [:seconds])

      assert message =~ "Expected one of [:seconds]"
    end
  end

  describe "due_at" do
    test "places the deadline the stated number of milliseconds past the field" do
      from = ago(0)

      assert Scheduler.due_at(nudge(), record(from)) ==
               DateTime.add(from, 250, :millisecond)
    end

    test "carries the unit through to the work's deadline" do
      assert nudge().deadline == %{field: :deadline_from, after: {250, :milliseconds}}
    end
  end

  describe "firing" do
    test "a deadline 250 milliseconds past the field is not yet due" do
      record = record(ago(0))

      assert Timeline.run_due(@resource) == 0
      assert Ash.get!(@resource, record.id).state == :waiting
    end

    test "a deadline whose 250 milliseconds have passed fires" do
      record = record(ago(400))

      assert Timeline.run_due(@resource) == 1
      assert Ash.get!(@resource, record.id).state == :escalated
    end
  end
end
