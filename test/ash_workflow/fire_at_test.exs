defmodule AshWorkflow.FireAtTest do
  @moduledoc """
  `fire_at` names the field holding the deadline instant, so the timeout is due
  once that instant has passed and not before.

  These run under `AshWorkflow.Scheduler.Precise`, through
  `AshWorkflow.Scheduler.Precise.Timeline.run_due/2`, which is the synchronous
  counterpart to its timers.
  """
  use ExUnit.Case, async: false

  alias Ash.DataLayer.Ets
  alias AshWorkflow.Scheduler
  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.FireAtWorkflow

  @resource FireAtWorkflow
  @table_manager Module.concat(FireAtWorkflow, Ash.DataLayer.Ets.TableManager)

  setup do
    on_exit(&reset_storage/0)

    :ok
  end

  # `Ash.DataLayer.Ets.stop/1` returns before the table's manager has gone, so
  # the next test would insert into a table that is about to be taken down.
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

  defp record(next_check_at) do
    FireAtWorkflow.create!(%{title: "one", next_check_at: next_check_at})
  end

  defp state(record), do: Ash.get!(@resource, record.id).state

  defp in_ms(ms), do: DateTime.add(DateTime.utc_now(), ms, :millisecond)

  test "fires once the instant the field holds has passed" do
    record = record(in_ms(-1_000))

    assert Timeline.run_due(@resource) == 1
    assert state(record) == :reviewed
  end

  test "does not fire before that instant" do
    record = record(in_ms(60_000))

    assert Timeline.run_due(@resource) == 0
    assert state(record) == :waiting
  end

  test "does not fire while the field is nil" do
    record = record(nil)

    assert Timeline.run_due(@resource) == 0
    assert state(record) == :waiting
  end

  test "fires against an expression calculation" do
    record = record(in_ms(-1_000))
    calculating = FireAtWorkflow.start_calculating!(record)

    assert calculating.state == :calculated
    assert Timeline.run_due(@resource) == 1
    assert state(record) == :reviewed
  end

  describe "the sweep, for a fire_at calculation" do
    test "arms a timer from a deadline nobody loaded" do
      # `AshWorkflow.Scheduler.due_at/2` reads the deadline field with
      # `Map.get/2`, which finds `%Ash.NotLoaded{}` for a calculation nothing
      # loaded, so the sweep loads it with the records it arms timers from.
      record = record(in_ms(300))
      FireAtWorkflow.start_calculating!(record)

      start_supervised!({Timeline, resources: [@resource], look_ahead_ms: 20})

      assert await_state(record, :reviewed, 3_000) == :reviewed
    end
  end

  defp await_state(record, state, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    await_state(record, state, deadline, nil)
  end

  defp await_state(record, state, deadline, last) do
    current =
      case Ash.get(@resource, record.id) do
        {:ok, reloaded} -> reloaded.state
        {:error, _not_found} -> :missing
      end

    cond do
      current == state -> current
      System.monotonic_time(:millisecond) > deadline -> last || current
      true -> Process.sleep(10) && await_state(record, state, deadline, current)
    end
  end

  describe "due_at" do
    test "is the field's own value, with no offset" do
      next_check_at = in_ms(60_000)
      record = record(next_check_at)

      work = work(:__timeout_trigger_waiting_review)

      assert Scheduler.due_at(work, record) == next_check_at
    end

    test "is nil while the field is nil" do
      record = record(nil)

      assert Scheduler.due_at(work(:__timeout_trigger_waiting_review), record) == nil
    end

    test "is nil for a calculation nothing has loaded" do
      record = record(in_ms(60_000))
      calculating = FireAtWorkflow.start_calculating!(record)

      work = work(:__timeout_trigger_calculated_calculated_review)

      assert Scheduler.due_at(work, calculating) == nil
    end
  end

  describe "pending_deadlines" do
    test "reports the field's value as the due_at" do
      next_check_at = in_ms(60_000)
      record = record(next_check_at)

      loaded = Ash.load!(record, :pending_deadlines)

      assert [%{name: :review, due_at: ^next_check_at, kind: :transition, target: :reviewed}] =
               loaded.pending_deadlines
    end

    test "omits a timeout whose field is nil" do
      loaded = nil |> record() |> Ash.load!(:pending_deadlines)

      assert loaded.pending_deadlines == []
    end
  end

  defp work(name) do
    @resource
    |> AshWorkflow.Info.scheduled_work()
    |> Enum.find(&(&1.name == name))
  end
end
