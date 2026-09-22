defmodule AshWorkflow.Scheduler.PreciseStateAttributeTest do
  @moduledoc """
  `AshWorkflow.Scheduler.Precise.Timeline` rebuilds the step predicate for its
  sweep rather than reusing `AshWorkflow.Scheduler.Work.match`, so that the
  horizon's bound reaches the data layer as a bind parameter. These tests cover
  that the rebuilt predicate reads the attribute the workflow named with
  `state_attribute`, which `AshWorkflowTest.PreciseStatusWorkflow` renames to
  `status`.
  """
  use ExUnit.Case, async: false

  alias Ash.DataLayer.Ets
  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.PreciseStatusWorkflow

  @resource PreciseStatusWorkflow
  @table_manager Module.concat(PreciseStatusWorkflow, Ash.DataLayer.Ets.TableManager)

  setup do
    on_exit(&reset_storage/0)

    :ok
  end

  # See the note in AshWorkflow.Scheduler.PreciseTest: stopping the table
  # without waiting for its manager to go leaves the next test inserting into
  # a table that is about to be taken down.
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

  defp candidate(deadline_from) do
    @resource
    |> Ash.Changeset.for_create(:create, %{title: "one", deadline_from: deadline_from})
    |> Ash.create!()
  end

  defp ago(ms), do: DateTime.add(DateTime.utc_now(), -ms, :millisecond)

  defp current_status(record) do
    case Ash.get(@resource, record.id) do
      {:ok, reloaded} -> reloaded.status
      {:error, _not_found} -> :missing
    end
  end

  defp await_status(record, status, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    await_status(record, status, deadline, nil)
  end

  defp await_status(record, status, deadline, last) do
    current = current_status(record)

    cond do
      current == status ->
        {:ok, current}

      System.monotonic_time(:millisecond) > deadline ->
        {:timeout, if(current == :missing, do: last || current, else: current)}

      true ->
        Process.sleep(10)
        await_status(record, status, deadline, last)
    end
  end

  defp start_timeline(opts) do
    opts = Keyword.merge([resources: [@resource], look_ahead_ms: 60_000], opts)

    start_supervised!({Timeline, opts})
  end

  describe "a workflow that renamed its state attribute" do
    test "the recovery sweep finds a record past its deadline" do
      # The sweep is the path that rebuilds the filter. Nothing arms this
      # record, so reaching :escalated means the rebuilt predicate matched on
      # `status`. A predicate naming `state` matches nothing here and the
      # record sits in :waiting until the assertion times out.
      record = candidate(ago(5_000))

      start_timeline(look_ahead_ms: 50)

      assert {:ok, :escalated} = await_status(record, :escalated, 2_000)
    end

    test "the sweep arms a deadline inside the horizon rather than firing it" do
      record = candidate(ago(500))

      start_timeline(look_ahead_ms: 50, horizon_ms: 30_000)

      assert {:ok, :escalated} = await_status(record, :escalated, 2_000)
    end

    test "entering the step arms the deadline" do
      start_timeline([])

      record = candidate(ago(800))

      assert {:ok, :escalated} = await_status(record, :escalated, 2_000)
    end
  end
end
