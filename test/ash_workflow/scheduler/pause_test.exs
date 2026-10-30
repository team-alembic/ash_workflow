defmodule AshWorkflow.Scheduler.PauseTest do
  @moduledoc """
  `AshWorkflow.Scheduler.pause/1` under `AshWorkflow.Scheduler.Precise`, and
  the pause count itself.

  Not async: the pause holds every scheduler on the node.
  """
  use ExUnit.Case, async: false

  alias Ash.DataLayer.Ets
  alias AshWorkflow.Scheduler
  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.FireAtWorkflow

  @resource FireAtWorkflow
  @table_manager Module.concat(FireAtWorkflow, Ash.DataLayer.Ets.TableManager)

  setup do
    on_exit(fn ->
      resume_all()
      reset_storage()
    end)

    :ok
  end

  defp resume_all do
    if Scheduler.paused?() do
      Scheduler.resume()
      resume_all()
    end
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

  defp overdue_record do
    FireAtWorkflow.create!(%{
      title: "one",
      next_check_at: DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    })
  end

  defp state(record), do: Ash.get!(@resource, record.id).state

  test "run_due fires nothing while paused, and the overdue deadline after the resume" do
    record = overdue_record()

    AshWorkflow.with_scheduler_paused(fn ->
      assert Timeline.run_due(@resource) == 0
      assert state(record) == :waiting
    end)

    assert Timeline.run_due(@resource) == 1
    assert state(record) == :reviewed
  end

  test "the timeline holds an overdue deadline while paused and fires it after the resume" do
    record = overdue_record()

    Scheduler.pause()
    start_supervised!({Timeline, resources: [@resource], look_ahead_ms: 20})

    Process.sleep(200)
    assert state(record) == :waiting

    Scheduler.resume()

    assert await_state(record, :reviewed, 3_000) == :reviewed
  end

  test "pauses nest" do
    Scheduler.pause()
    Scheduler.pause()
    Scheduler.resume()

    assert Scheduler.paused?()

    Scheduler.resume()

    refute Scheduler.paused?()
  end

  test "with_scheduler_paused returns the function's result and resumes" do
    assert AshWorkflow.with_scheduler_paused(fn -> Scheduler.paused?() end)
    refute Scheduler.paused?()
  end

  test "with_scheduler_paused resumes when the function raises" do
    assert_raise RuntimeError, fn ->
      AshWorkflow.with_scheduler_paused(fn -> raise "replay failed" end)
    end

    refute Scheduler.paused?()
  end

  test "pause applies to the nodes it is given" do
    Scheduler.pause(nodes: [node()])
    assert Scheduler.paused?()

    Scheduler.resume(nodes: [node()])
    refute Scheduler.paused?()
  end

  defp await_state(record, state, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    await_state(record, state, deadline, nil)
  end

  defp await_state(record, state, deadline, last) do
    current = state(record)

    cond do
      current == state -> current
      System.monotonic_time(:millisecond) > deadline -> last || current
      true -> Process.sleep(10) && await_state(record, state, deadline, current)
    end
  end
end
