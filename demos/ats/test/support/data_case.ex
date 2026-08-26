defmodule AshWorkflowDemo.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use AshWorkflowDemo.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias AshWorkflowDemo.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import AshWorkflowDemo.DataCase
    end
  end

  setup tags do
    AshWorkflowDemo.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Runs the workflow's Oban triggers to completion, the way the DemoScheduler
  does on stage. Tests that call an action directly prove the action works;
  this proves the workflow actually drives it.
  """
  def run_workflow_triggers(resource, passes \\ 5) do
    # Each pass schedules from the state the last pass left behind. The demo
    # chains :submitted -> :verifying -> :review, and a scheduler only sees the
    # state a record is in when it runs, so one pass is not enough.
    Enum.reduce_while(1..passes, nil, fn _, _ ->
      AshOban.schedule_and_run_triggers(resource)
      result = Oban.drain_queue(queue: :workflow, with_recursion: true, with_scheduled: true)

      if result.success + result.failure + result.discard == 0 do
        {:halt, result}
      else
        {:cont, result}
      end
    end)
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
      AshWorkflowDemo.Repo.update_all(
        from(r in table, where: r.id == type(^record.id, :binary_id)),
        set: [{field, value}]
      )

    Map.put(record, field, value)
  end

  @doc "Reloads a record, bypassing authorization."
  def reload(record), do: Ash.get!(record.__struct__, record.id, authorize?: false)

  @doc """
  Sets the moment the scorer may pick a candidate up. `:submitted` is a wait
  state gated on this field, so a test that wants verification to happen has to
  put the deadline in the past.
  """
  def ready_to_verify(candidate),
    do: set_datetime(candidate, :verify_after, DateTime.add(DateTime.utc_now(), -1, :second))

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(AshWorkflowDemo.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
