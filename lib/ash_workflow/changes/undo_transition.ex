defmodule AshWorkflow.Changes.UndoTransition do
  @moduledoc """
  Performs the state half of an undo: resolves the row to reverse, rewinds the
  record to that row's `from_state`, and hands the row to
  `AshWorkflow.Changes.RecordEvent` through the changeset context so the new
  log row can point at it.

  The target is only known once the log has been read, so this cannot be an
  atomic update — the same reason `AshWorkflow.Changes.ConditionalTransition`
  opts out. A changeset filter on the current state closes the resulting
  window: if a concurrent transition moves the record between the read and the
  write, the update matches no rows and Ash raises a stale-record error rather
  than rewinding to a state that is no longer the one being undone.

  Used internally by `AshWorkflow.Transformers.AddActions`. Not intended for
  direct use.
  """
  use Ash.Resource.Change

  require Ash.Expr

  alias AshWorkflow.Undo

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Undo.resolve(changeset.data, context.actor) do
        {:ok, %{target: target, row: row}} ->
          state_attribute =
            AshStateMachine.Info.state_machine_state_attribute!(changeset.resource)

          changeset
          |> Ash.Changeset.filter(Ash.Expr.expr(^Ash.Expr.ref(state_attribute) == ^row.to_state))
          |> Ash.Changeset.put_context(:ash_workflow, %{undoes: row})
          |> AshStateMachine.transition_state(target)

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end)
  end
end
