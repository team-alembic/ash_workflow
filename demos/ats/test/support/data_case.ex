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
  Runs every deadline and automatic step that is due, until nothing is left.

  On stage `AshWorkflow.Scheduler.Precise.Timeline` fires these from its own
  process, on a timer. A test cannot wait for that: the timeline holds no
  sandbox connection, so work it ran could not see the test's data.
  `AshWorkflow.Scheduler.Precise.run_due/2` runs the same work through
  `AshWorkflow.Scheduler.execute/3` on the test's own connection instead.

  Tests that call an action directly prove the action works; this proves the
  workflow actually drives it.
  """
  def run_workflow_triggers(resource, passes \\ 5) do
    # Each pass runs from the state the last pass left behind. A deadline
    # firing on :hr_screen lands on :hr_decision, whose action then routes on
    # to :background_check or :rejected in the same pass it was entered, but
    # work is only due for the state a record is in when a pass starts, so one
    # pass is not enough to walk the whole chain.
    Enum.reduce_while(1..passes, 0, fn _, _ ->
      case AshWorkflow.Scheduler.Precise.run_due(resource) do
        0 -> {:halt, 0}
        count -> {:cont, count}
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
  Sets the moment Janine is due to answer into the past, so `:hr_screen`'s
  `:janine_responds` timeout is due the next time triggers run.
  """
  def ready_for_hr_decision(candidate),
    do: set_datetime(candidate, :hr_respond_after, DateTime.add(DateTime.utc_now(), -1, :second))

  @doc """
  Sets the moment Steve is due to answer into the past, so `:lead_interview`'s
  `:steve_responds` timeout is due the next time triggers run.
  """
  def ready_for_lead_decision(candidate),
    do:
      set_datetime(candidate, :lead_respond_after, DateTime.add(DateTime.utc_now(), -1, :second))

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
