defmodule AshWorkflow.Scheduler.PreciseActionTimeoutTest do
  @moduledoc """
  An action timeout under `AshWorkflow.Scheduler.Precise` fires once for each
  deadline.

  Before `<step>_<timeout>_fired_at`, firing left the record matching, so the
  `Timeline` fired it again on every rearm and `run_due/2` never returned 0.
  See issue #106.
  """
  use ExUnit.Case, async: false

  alias Ash.DataLayer.Ets
  alias AshWorkflow.Scheduler.Precise
  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.PreciseActionTimeoutWorkflow

  @resource PreciseActionTimeoutWorkflow
  @table_manager Module.concat(PreciseActionTimeoutWorkflow, Ash.DataLayer.Ets.TableManager)

  setup do
    on_exit(&reset_storage/0)
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

  defp create(deadline_from_ms_ago) do
    @resource
    |> Ash.Changeset.for_create(:create, %{
      deadline_from: DateTime.add(DateTime.utc_now(), -deadline_from_ms_ago, :millisecond)
    })
    |> Ash.create!()
  end

  # `:reminder` is due 4 seconds ago. `:final_reminder` is 55 seconds out.
  defp create_due, do: create(5_000)

  defp reload(record), do: Ash.get!(@resource, record.id)

  test "the Timeline runs a due action timeout once" do
    # Created before the Timeline starts, so the create's rearm reaches no
    # process and only the start-up sweep finds the record. look_ahead_ms is
    # 60 s, so no second sweep runs inside this test.
    record = create_due()

    start_supervised!({Timeline, resources: [@resource], look_ahead_ms: 60_000})
    Process.sleep(1_000)
    stop_supervised!(Timeline)

    assert reload(record).reminders == 1
  end

  test "run_due/2 reaches 0, as its docs say a loop over it must" do
    record = create_due()

    runs = for _ <- 1..5, do: Precise.run_due(@resource)

    assert runs == [1, 0, 0, 0, 0]
    assert reload(record).reminders == 1
  end

  test "firing writes the fired column of every timeout on the step that runs the action" do
    record = create_due()

    Precise.run_due(@resource)
    record = reload(record)

    assert %DateTime{} = record.waiting_reminder_fired_at
    assert %DateTime{} = record.waiting_final_reminder_fired_at
  end

  test "a later timeout sharing the action still fires after an earlier one wrote its column" do
    # `:reminder` is due now, `:final_reminder` half a second from now. Firing
    # `:reminder` writes both columns, since they share `send_reminder`, and
    # `:final_reminder` still fires because its column is before its deadline.
    record = create(59_500)

    assert Precise.run_due(@resource) == 1
    assert reload(record).reminders == 1

    Process.sleep(600)

    assert Precise.run_due(@resource) == 1
    assert Precise.run_due(@resource) == 0
    assert reload(record).reminders == 2
  end

  test "pending_deadlines omits the timeout that fired and keeps the one still ahead" do
    record = create_due()

    assert [%{name: :reminder}, %{name: :final_reminder}] = pending_deadlines(record)

    Precise.run_due(@resource)

    assert [%{name: :final_reminder}] = record |> reload() |> pending_deadlines()
  end

  defp pending_deadlines(record) do
    record |> Ash.load!(:pending_deadlines) |> Map.fetch!(:pending_deadlines)
  end
end
