defmodule AshWorkflowTest.RecipeFixtures.Sync.FakePush do
  @moduledoc """
  Stands in for the change an application adds to a generated `:push` action.

  Each push of a sync takes the next outcome queued for it with `respond/2`,
  and succeeds when none is queued. The queue is keyed by the sync's id rather
  than held by the calling process, because a scheduler pushes from its own.
  """
  use Ash.Resource.Change

  @spec respond(Ash.Resource.record(), [:ok | :error]) :: :ok
  def respond(sync, outcomes), do: :persistent_term.put(key(sync.id), outcomes)

  @spec remaining(Ash.Resource.record()) :: [:ok | :error]
  def remaining(sync), do: :persistent_term.get(key(sync.id), [])

  @impl true
  def change(changeset, _opts, _context) do
    id = changeset.data.id

    case :persistent_term.get(key(id), []) do
      [:error | rest] ->
        :persistent_term.put(key(id), rest)
        Ash.Changeset.add_error(changeset, "the external system is unavailable")

      outcomes ->
        :persistent_term.put(key(id), Enum.drop(outcomes, 1))
        Ash.Changeset.force_change_attribute(changeset, :external_id, "ext-#{id}")
    end
  end

  defp key(id), do: {__MODULE__, id}
end
