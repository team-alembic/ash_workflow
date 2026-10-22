defmodule AshWorkflowTest.RecipeFixtures.Sync.FakePush do
  @moduledoc """
  Stands in for the change an application adds to a generated `:push` action.

  Each push of a sync takes the next outcome queued for it with `respond/2`,
  and succeeds when none is queued. The queue is keyed by the sync's id in a
  public ETS table rather than held by the calling process, because a
  scheduler pushes from its own. Call `start/0` from `setup_all`.
  """
  use Ash.Resource.Change

  @table __MODULE__

  @spec start() :: :ok
  def start do
    :ets.new(@table, [:named_table, :public, :set])
    :ok
  end

  @spec respond(Ash.Resource.record(), [:ok | :error]) :: :ok
  def respond(sync, outcomes) do
    :ets.insert(@table, {sync.id, outcomes})
    :ok
  end

  @spec remaining(Ash.Resource.record()) :: [:ok | :error]
  def remaining(sync), do: outcomes(sync.id)

  @impl true
  def change(changeset, _opts, _context) do
    id = changeset.data.id

    case outcomes(id) do
      [:error | rest] ->
        :ets.insert(@table, {id, rest})
        Ash.Changeset.add_error(changeset, "the external system is unavailable")

      [:ok | rest] ->
        :ets.insert(@table, {id, rest})
        succeed(changeset, id)

      [] ->
        succeed(changeset, id)
    end
  end

  defp succeed(changeset, id),
    do: Ash.Changeset.force_change_attribute(changeset, :external_id, "ext-#{id}")

  defp outcomes(id) do
    case :ets.lookup(@table, id) do
      [{^id, outcomes}] -> outcomes
      [] -> []
    end
  end
end
