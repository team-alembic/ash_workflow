defmodule AshWorkflow.Scheduler.PreciseCalculatedDeadlineTest do
  @moduledoc """
  `AshWorkflow.Scheduler.Precise` arms a `fire_at` deadline read from a
  calculation as soon as a record enters the step.

  The record `AshWorkflow.Changes.RecordEvent` hands on does not have the
  calculation loaded, so `AshWorkflow.Scheduler.due_at/2` could not compute the
  deadline, and only the recovery sweep armed it, up to `look_ahead_ms` late.

  `expiring_at` is `datetime_add(expires_at, -1, :day)`, which Ash truncates
  to whole seconds when it evaluates the calculation in memory, so each
  deadline here is known to within a second.
  """
  use ExUnit.Case, async: false

  alias Ash.DataLayer.Ets
  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.PreciseCalculatedDeadlineWorkflow

  @resource PreciseCalculatedDeadlineWorkflow
  @table_manager Module.concat(PreciseCalculatedDeadlineWorkflow, Ash.DataLayer.Ets.TableManager)

  setup do
    on_exit(&reset_storage/0)

    # The sweep is a minute away, so any timer these tests see was armed by
    # the create itself.
    start_supervised!({Timeline, resources: [@resource], look_ahead_ms: 60_000})

    :ok
  end

  # See `AshWorkflow.Scheduler.PreciseTest` for why the table manager has to
  # be gone before the next test starts.
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

  defp expiring_in(ms) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(1, :day)
      |> DateTime.add(ms, :millisecond)

    PreciseCalculatedDeadlineWorkflow.create!(%{expires_at: expires_at})
  end

  test "creating the record arms a timer for the calculated deadline" do
    record = expiring_in(10_000)

    %Timeline{timers: timers} = :sys.get_state(Timeline)
    key = {@resource, :__timeout_trigger_active_expire, [record.id]}

    assert %{^key => timer} = timers
    assert Process.read_timer(timer) in 8_000..10_100
  end

  test "the armed timer fires the timeout" do
    record = expiring_in(1_500)

    assert await_state(record, :expired, 3_000) == :expired
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
end
