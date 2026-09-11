defmodule AshWorkflowTest.Changes.RecordSignature do
  @moduledoc """
  Writes `signed_by` from the action's own logic rather than from caller input.

  The routes on `:sign_off` read the same attribute, so this is what proves a
  route sees the record as it was when the call arrived rather than what the
  action is about to write.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.change_attribute(changeset, :signed_by, "signer")
  end
end
