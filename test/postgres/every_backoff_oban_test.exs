defmodule AshWorkflowTest.Postgres.EveryBackoffObanTest do
  @moduledoc """
  Exercises `max_fires` and `backoff` through the generated Oban triggers.

  `AshWorkflowTest.Postgres.EveryBackoffWorkflow` declares one `every` per
  bound, each with atomic actions, so each fire count is incremented in SQL
  and each `where` clause is compiled to SQL. `set_columns/2` writes straight
  through Ecto so a test can place a record on either side of a gap.
  """
  use AshWorkflowTest.DataCase

  import Ecto.Query

  alias AshWorkflow.Entities.Every
  alias AshWorkflowTest.Postgres.EveryBackoffWorkflow, as: Workflow
  alias AshWorkflowTest.Repo

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp set_columns(record, values) do
    {1, _} =
      Repo.update_all(
        from(r in "every_backoff_workflows", where: r.id == type(^record.id, :binary_id)),
        set: Enum.to_list(values)
      )

    record
  end

  defp run!(every) do
    AshOban.schedule_and_run_triggers({Workflow, :"__every_trigger_waiting_#{every}"})
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)
  end

  defp reload(record), do: Ash.get!(Workflow, record.id, authorize?: false)

  defp submit! do
    Workflow.submit!(%{title: "one"})
    |> set_columns(state_entered_at: ago(86_400))
  end

  test "max_fires stops the trigger matching once the count is reached" do
    record = submit!()

    for expected <- 1..2 do
      set_columns(record, waiting_capped_last_fired_at: ago(3_660))
      run!(:capped)
      assert reload(record).waiting_capped_fires == expected
    end

    set_columns(record, waiting_capped_last_fired_at: ago(3_660))
    run!(:capped)

    reloaded = reload(record)
    assert reloaded.waiting_capped_fires == 2
    assert DateTime.diff(DateTime.utc_now(), reloaded.waiting_capped_last_fired_at) >= 3_600
  end

  test "a fixed backoff adds its duration to every gap after the first" do
    record = submit!()

    run!(:fixed)
    assert reload(record).waiting_fixed_fires == 1

    set_columns(record, waiting_fixed_last_fired_at: ago(3 * 3_600 - 60))
    run!(:fixed)
    assert reload(record).waiting_fixed_fires == 1

    set_columns(record, waiting_fixed_last_fired_at: ago(3 * 3_600 + 60))
    run!(:fixed)
    assert reload(record).waiting_fixed_fires == 2
  end

  test "an exponential backoff matches the gap Every.gap_ms/3 computes" do
    record = submit!()

    for fires <- [1, 4, 8] do
      gap_seconds = div(Every.gap_ms({1, :hours}, :exponential, fires), 1_000)

      set_columns(record,
        waiting_exponential_last_fired_at: ago(gap_seconds - 5),
        waiting_exponential_fires: fires
      )

      run!(:exponential)
      assert reload(record).waiting_exponential_fires == fires

      set_columns(record, waiting_exponential_last_fired_at: ago(gap_seconds + 5))
      run!(:exponential)
      assert reload(record).waiting_exponential_fires == fires + 1
    end
  end
end
