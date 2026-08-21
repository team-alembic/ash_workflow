defmodule SubscriptionDunning.DataCase do
  @moduledoc """
  Case template for the demo's tests.

  Not async: Oban's queues are drained explicitly and its jobs table is shared,
  so these run serially against one sandbox-checked-out connection.
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      use Oban.Testing, repo: SubscriptionDunning.Repo, prefix: "public"

      import SubscriptionDunning.DataCase
    end
  end

  setup _tags do
    :ok = Sandbox.checkout(SubscriptionDunning.Repo)
    :ok
  end

  @doc """
  Runs every AshWorkflow trigger for `resource` to completion.

  Schedules the triggers, then drains recursively so that work a scheduler
  enqueues — including a step's `on_error` handler — runs in the same call.
  """
  def run_workflow_triggers(resource) do
    AshOban.schedule_and_run_triggers(resource)
    Oban.drain_queue(queue: :workflow, with_recursion: true, with_scheduled: true)
  end

  @doc """
  Rewinds `state_entered_at` so a timeout's deadline has passed, without the
  test waiting for wall-clock time.
  """
  def age_by(record, amount, unit) do
    set_datetime(record, :state_entered_at, DateTime.add(DateTime.utc_now(), -amount, unit))
  end

  @doc "Forces a datetime attribute directly, bypassing the state machine."
  def set_datetime(record, field, value) do
    import Ecto.Query

    table = AshPostgres.DataLayer.Info.table(record.__struct__)

    {1, _} =
      SubscriptionDunning.Repo.update_all(
        from(r in table, where: r.id == type(^record.id, :binary_id)),
        set: [{field, value}]
      )

    Map.put(record, field, value)
  end
end
