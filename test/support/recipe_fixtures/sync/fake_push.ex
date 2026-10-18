defmodule AshWorkflowTest.RecipeFixtures.Sync.FakePush do
  @moduledoc """
  Stands in for the change an application adds to a generated `:push` action.

  Each push takes the next outcome queued with `respond/1` in the calling
  process, and succeeds when none is queued.
  """
  use Ash.Resource.Change

  @spec respond([:ok | :error]) :: :ok
  def respond(outcomes) do
    Process.put(__MODULE__, outcomes)
    :ok
  end

  @impl true
  def change(changeset, _opts, _context) do
    case Process.get(__MODULE__, []) do
      [:error | rest] ->
        Process.put(__MODULE__, rest)
        Ash.Changeset.add_error(changeset, "the external system is unavailable")

      outcomes ->
        Process.put(__MODULE__, Enum.drop(outcomes, 1))
        Ash.Changeset.force_change_attribute(changeset, :external_id, "ext-#{changeset.data.id}")
    end
  end
end
