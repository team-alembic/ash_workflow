defmodule AshWorkflowTest.DataCase do
  @moduledoc """
  Case template for tests that hit Postgres.

  Not async: Oban's queues are driven explicitly and its jobs table is shared,
  so these tests run serially against a single sandbox-checked-out connection.
  """
  use ExUnit.CaseTemplate

  import Ecto.Query

  alias AshPostgres.DataLayer.Info, as: DataLayerInfo
  alias AshWorkflowTest.Repo
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      use Oban.Testing, repo: unquote(Repo), prefix: "public"

      import AshWorkflowTest.DataCase
    end
  end

  setup _tags do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  @doc """
  Rewinds `state_entered_at` so a timeout's `fire_after` duration has elapsed,
  without the test having to wait for wall-clock time.

  Writes through Ecto rather than an Ash action: the resource deliberately has
  no generic update action, and the point is to move the clock without going
  through the state machine.
  """
  def age_by(record, amount, unit), do: age_field_by(record, :state_entered_at, amount, unit)

  @doc """
  Ages an arbitrary datetime column on a record's row, the same way `age_by/3`
  ages `state_entered_at` — writing through Ecto so a test can put an `every`'s
  own last-fired column, or `state_entered_at`, on either side of a bound
  without waiting for a fire to actually happen.
  """
  def age_field_by(record, field, amount, unit) do
    at = DateTime.add(DateTime.utc_now(), -amount, unit)
    table = DataLayerInfo.table(record.__struct__)

    {1, _} =
      Repo.update_all(
        from(r in table, where: r.id == type(^record.id, :binary_id)),
        set: [{field, at}]
      )

    Map.put(record, field, at)
  end

  @doc """
  Writes an exact instant into a datetime column, the same way `age_field_by/4`
  writes a relative one.

  A wall-clock `every` is due relative to the most recent occurrence of a local
  time, not relative to now, so its tests need to place a record on either side
  of that occurrence rather than a fixed number of hours back.
  """
  def set_field(record, field, %DateTime{} = at) do
    table = DataLayerInfo.table(record.__struct__)

    {1, _} =
      Repo.update_all(
        from(r in table, where: r.id == type(^record.id, :binary_id)),
        set: [{field, at}]
      )

    Map.put(record, field, at)
  end
end
