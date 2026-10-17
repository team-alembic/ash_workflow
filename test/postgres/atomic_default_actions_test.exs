defmodule AshWorkflowTest.Postgres.AtomicDefaultActionsTest do
  @moduledoc """
  Runs workflow actions that leave `require_atomic?` at Ash's default on a
  repo that cannot compile `error/2`, which `transition_state` needs on the
  atomic path. AshOban triggers request the `:stream` strategy, so only a
  bulk update at the default strategy reaches the atomic path.
  """
  use AshWorkflowTest.DataCase

  import Ecto.Query, only: [from: 2]

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflowTest.NoExprErrorRepo
  alias AshWorkflowTest.Postgres.AtomicDefaultWorkflow
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(NoExprErrorRepo)
  end

  defp submit, do: AtomicDefaultWorkflow.submit!(%{title: "Q1 report"})

  defp bulk_update!(record, action) do
    assert %Ash.BulkResult{status: :success, records: [updated]} =
             Ash.bulk_update([record], action, %{},
               resource: AtomicDefaultWorkflow,
               return_records?: true,
               return_errors?: true
             )

    updated
  end

  defp require_atomic?(action_name) do
    ResourceInfo.action(AtomicDefaultWorkflow, action_name).require_atomic?
  end

  defp age_state_by(record, amount, unit) do
    at = DateTime.add(DateTime.utc_now(), -amount, unit)

    {1, _} =
      NoExprErrorRepo.update_all(
        from(r in "atomic_default_workflows", where: r.id == type(^record.id, :binary_id)),
        set: [state_entered_at: at]
      )

    record
  end

  defp run_triggers do
    AshOban.schedule_and_run_triggers(AtomicDefaultWorkflow)

    assert %{failure: 0, discard: 0} =
             Oban.drain_queue(queue: :workflow, with_recursion: true)
  end

  defp reload(record), do: Ash.get!(AtomicDefaultWorkflow, record.id)

  test "the automatic step action runs from its trigger" do
    record = submit()

    run_triggers()

    assert reload(record).state == :review
  end

  test "the generated non-conditional transition runs as a bulk update" do
    record =
      submit()
      |> Ash.update!(%{}, action: :run_checks)
      |> bulk_update!(:approve)

    assert record.state == :approved
  end

  test "the timeout action runs from its trigger" do
    record = submit() |> Ash.update!(%{}, action: :run_checks) |> age_state_by(2, :day)

    run_triggers()

    assert %{state: :review, reminders_sent: 1} = reload(record)
  end

  test "the generated non-conditional transition sets require_atomic? false" do
    refute require_atomic?(:approve)
  end
end
