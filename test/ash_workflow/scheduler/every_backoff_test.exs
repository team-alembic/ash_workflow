defmodule AshWorkflow.Scheduler.EveryBackoffTest do
  @moduledoc """
  `max_fires` bounds an `every` by fires per step visit, and `backoff` grows
  the gap after each fire. `AshWorkflowTest.EveryBackoffWorkflow` declares one
  `every` for each, and these tests drive them with
  `AshWorkflow.Scheduler.Precise.run_due/2`, placing each record's columns on
  either side of a gap instead of waiting for a clock.
  """
  use ExUnit.Case, async: false

  alias Ash.DataLayer.Ets
  alias AshWorkflow.Entities.Every
  alias AshWorkflow.Entities.Retry
  alias AshWorkflow.Scheduler.Precise
  alias AshWorkflowTest.EveryBackoffWorkflow, as: Workflow

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

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp set_clock(record, values) do
    record
    |> Ash.Changeset.for_update(:set_clock, %{values: values})
    |> Ash.update!()
  end

  defp reload(record), do: Ash.get!(Workflow, record.id)

  # Puts every `every` far from due except the one named, so a `run_due/2`
  # pass fires at most that one.
  defp only_due(record, values) do
    quiet = %{
      waiting_capped_last_fired_at: ago(60),
      waiting_fixed_last_fired_at: ago(60),
      waiting_exponential_last_fired_at: ago(60)
    }

    set_clock(record, Map.merge(%{state_entered_at: ago(86_400)}, Map.merge(quiet, values)))
  end

  describe "max_fires" do
    test "stops firing once the count is reached" do
      record = Workflow.create!(%{title: "one"})

      for expected <- 1..2 do
        only_due(record, %{waiting_capped_last_fired_at: ago(3_660)})

        assert Precise.run_due(Workflow) == 1
        reloaded = reload(record)
        assert reloaded.capped_count == expected
        assert reloaded.waiting_capped_fires == expected
      end

      only_due(record, %{waiting_capped_last_fired_at: ago(3_660)})

      assert Precise.run_due(Workflow) == 0
      assert reload(record).capped_count == 2
    end

    test "counts fires per step visit, so re-entering the step starts the count again" do
      record =
        Workflow.create!(%{title: "one"})
        |> only_due(%{waiting_capped_last_fired_at: ago(3_660), waiting_capped_fires: 2})

      assert Precise.run_due(Workflow) == 0

      record =
        record
        |> reload()
        |> Ash.Changeset.for_update(:pause, %{})
        |> Ash.update!()
        |> Ash.Changeset.for_update(:resume, %{})
        |> Ash.update!()

      # The last fire is now from before `state_entered_at`, in the previous
      # visit. Only `:capped` is left due, one interval after re-entry.
      set_clock(record, %{
        state_entered_at: ago(3_660),
        waiting_capped_last_fired_at: ago(7_200),
        waiting_fixed_last_fired_at: ago(60),
        waiting_exponential_last_fired_at: ago(60)
      })

      assert Precise.run_due(Workflow) == 1

      reloaded = reload(record)
      assert reloaded.capped_count == 1
      assert reloaded.waiting_capped_fires == 1
    end
  end

  describe "fixed backoff" do
    test "the first fire lands one interval after entry" do
      record =
        Workflow.create!(%{title: "one"})
        |> set_clock(%{
          state_entered_at: ago(3_660),
          waiting_capped_last_fired_at: ago(60),
          waiting_exponential_last_fired_at: ago(60)
        })

      assert Precise.run_due(Workflow) == 1
      assert reload(record).waiting_fixed_fires == 1
    end

    test "later gaps are the interval plus the backoff" do
      record =
        Workflow.create!(%{title: "one"})
        |> only_due(%{waiting_fixed_last_fired_at: ago(3_660), waiting_fixed_fires: 1})

      assert Precise.run_due(Workflow) == 0

      only_due(record, %{waiting_fixed_last_fired_at: ago(3 * 3_600 - 60)})
      assert Precise.run_due(Workflow) == 0

      only_due(record, %{waiting_fixed_last_fired_at: ago(3 * 3_600 + 60)})
      assert Precise.run_due(Workflow) == 1
      assert reload(record).waiting_fixed_fires == 2
    end
  end

  describe "exponential backoff" do
    test "the gap after fire n is the interval plus Retry.delay_ms/2 for attempt n" do
      record = Workflow.create!(%{title: "one"})

      for fires <- [1, 3, 6] do
        gap_seconds = div(Every.gap_ms({1, :hours}, :exponential, fires), 1_000)
        assert gap_seconds == 3_600 + div(Retry.delay_ms(%Retry{}, fires), 1_000)

        only_due(record, %{
          waiting_exponential_last_fired_at: ago(gap_seconds - 5),
          waiting_exponential_fires: fires
        })

        assert Precise.run_due(Workflow) == 0

        only_due(record, %{
          waiting_exponential_last_fired_at: ago(gap_seconds + 5),
          waiting_exponential_fires: fires
        })

        assert Precise.run_due(Workflow) == 1
        assert reload(record).waiting_exponential_fires == fires + 1
      end
    end
  end

  describe "pending_deadlines" do
    test "reports the grown gap, and omits an every that has used up its fires" do
      last_fired_at = ago(60)

      record =
        Workflow.create!(%{title: "one"})
        |> only_due(%{
          waiting_capped_last_fired_at: last_fired_at,
          waiting_capped_fires: 2,
          waiting_fixed_last_fired_at: last_fired_at,
          waiting_fixed_fires: 1,
          waiting_exponential_last_fired_at: last_fired_at,
          waiting_exponential_fires: 2
        })

      deadlines =
        record
        |> reload()
        |> Ash.load!(:pending_deadlines)
        |> Map.fetch!(:pending_deadlines)
        |> Map.new(&{&1.name, &1.due_at})

      refute Map.has_key?(deadlines, :capped)
      assert DateTime.diff(deadlines.fixed, last_fired_at, :second) == 3 * 3_600
      assert DateTime.diff(deadlines.exponential, last_fired_at, :second) == 3_600 + 16 + 15
    end
  end

  describe "Every.next_due_at/5" do
    test "measures the first fire from state_entered_at, and ignores a fire from an earlier visit" do
      entered = ~U[2026-01-01 00:00:00.000000Z]

      assert Every.next_due_at({1, :hours}, :exponential, nil, 0, entered) ==
               ~U[2026-01-01 01:00:00.000000Z]

      assert Every.next_due_at(
               {1, :hours},
               {2, :hours},
               ~U[2026-01-01 00:30:00.000000Z],
               1,
               entered
             ) ==
               ~U[2026-01-01 03:30:00.000000Z]

      assert Every.next_due_at(
               {1, :hours},
               {2, :hours},
               ~U[2025-12-31 00:00:00.000000Z],
               4,
               entered
             ) ==
               ~U[2025-12-31 01:00:00.000000Z]
    end
  end
end
