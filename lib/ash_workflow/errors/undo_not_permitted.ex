defmodule AshWorkflow.Errors.UndoNotPermitted do
  @moduledoc """
  Raised (or returned) when `undo` is called on a record that cannot be
  rewound.

  The `reason` field says which rule refused, so callers can branch without
  matching on message text:

    * `:undo_not_enabled` — the workflow has no `undo` block.
    * `:no_history` — the record's transition log has no state change to undo.
    * `:not_undoable` — the last state change came from a transition that is
      not marked `undoable?: true`. Automatic steps, timeouts, error paths and
      the initial row all land here.
    * `:window_expired` — the transition is older than the configured `within`.
    * `:different_actor` — `same_actor?` is set and the actor differs from the
      one recorded on the transition.
    * `:no_actor` — `same_actor?` is set and either the caller or the recorded
      transition has no actor.
    * `:stale` — the record moved on between reading the log and writing, so
      the row being undone is no longer the head.
  """
  use Splode.Error, fields: [:reason, :resource, :from_state, :to_state], class: :invalid

  @type reason ::
          :undo_not_enabled
          | :no_history
          | :not_undoable
          | :window_expired
          | :different_actor
          | :no_actor
          | :stale

  @impl true
  def message(%{reason: reason} = error) do
    "Cannot undo #{inspect(error.resource)}: #{describe(reason, error)}"
  end

  defp describe(:undo_not_enabled, _error) do
    "this workflow has no `undo` block. Add one to its `workflow` section."
  end

  defp describe(:no_history, _error) do
    "its transition log records no state change to undo."
  end

  defp describe(:not_undoable, error) do
    "the move #{inspect(error.from_state)} -> #{inspect(error.to_state)} is not undoable. " <>
      "Mark the transition `undoable?: true` if rewinding it is safe."
  end

  defp describe(:window_expired, _error) do
    "the undo window configured by `within` has passed."
  end

  defp describe(:different_actor, _error) do
    "`same_actor?` is set, and this transition was made by a different actor."
  end

  defp describe(:no_actor, _error) do
    "`same_actor?` is set, but there is no actor to compare — either none was " <>
      "given to this call, or none was recorded on the transition."
  end

  defp describe(:stale, _error) do
    "it changed state while the undo was being prepared."
  end
end
