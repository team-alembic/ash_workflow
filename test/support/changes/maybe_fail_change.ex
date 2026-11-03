defmodule AshWorkflowTest.Changes.MaybeFailChange do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def atomic(changeset, _opts, _context) do
    {:ok,
     Ash.Changeset.atomic_update(
       changeset,
       :should_fail,
       expr(
         if should_fail do
           error(Ash.Error.Changes.InvalidChanges, %{message: "Processing failed"})
         else
           should_fail
         end
       )
     )}
  end

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if Ash.Changeset.get_attribute(changeset, :should_fail) do
        Ash.Changeset.add_error(changeset, "Processing failed")
      else
        changeset
      end
    end)
  end
end
