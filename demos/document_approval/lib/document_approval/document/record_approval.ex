defmodule DocumentApproval.Document.RecordApproval do
  @moduledoc """
  Records which administrator signed off, and refuses a second signature from
  the administrator who already signed.

  Two-admin sign-off is only meaningful if the approvers are different people,
  and nothing in the workflow DSL can express "a different actor" — that is
  business logic, so it lives in a change.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: nil}) do
    Ash.Changeset.add_error(changeset,
      field: :first_approver_id,
      message: "an actor is required to approve a document"
    )
  end

  @impl true
  def change(changeset, _opts, %{actor: actor}) do
    case changeset.data.first_approver_id do
      nil ->
        Ash.Changeset.change_attribute(changeset, :first_approver_id, actor.id)

      first_approver_id when first_approver_id == actor.id ->
        Ash.Changeset.add_error(changeset,
          field: :second_approver_id,
          message: "you have already approved this document; a second administrator must sign off"
        )

      _other ->
        Ash.Changeset.change_attribute(changeset, :second_approver_id, actor.id)
    end
  end
end
