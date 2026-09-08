defmodule AshWorkflow.Undo do
  @moduledoc """
  Runtime resolution for the generated `undo` action: decides whether a record
  may be rewound, and to where.

  Undo reverses the most recent *state change* in the transition log. It is
  refused unless that change came from a transition declared `undoable?:
  true` — which is what keeps automatic steps, timeouts, error paths and the
  initial row out of reach, since none of them corresponds to an undoable
  transition. See `AshWorkflow.Errors.UndoNotPermitted` for the full set of
  refusals.

  Nothing here writes. The decision is separated from the write so it can be
  asked without side effects — `can_undo?/2` and `undo_target/2` are the same
  code path the action itself takes.
  """

  alias AshWorkflow.Entities.TransitionLog
  alias AshWorkflow.Entities.Undo, as: UndoConfig
  alias AshWorkflow.Errors.UndoNotPermitted
  alias AshWorkflow.Info
  alias AshWorkflow.TransitionLog, as: TransitionLogHelpers

  @typedoc """
  The resolved undo: the state to rewind to, and the log row being reversed.
  """
  @type resolution :: %{target: atom(), row: Ash.Resource.record()}

  @doc """
  Resolves the undo for `record`, or returns why it is refused.
  """
  @spec resolve(Ash.Resource.record(), term()) ::
          {:ok, resolution()} | {:error, Exception.t()}
  def resolve(record, actor \\ nil) do
    resource = record.__struct__

    with {:ok, config} <- fetch_config(resource),
         {:ok, row} <- fetch_head(record, resource),
         :ok <- check_undoable(resource, row),
         :ok <- check_window(config, row, resource),
         :ok <- check_actor(config, resource, row, actor) do
      {:ok, %{target: row.from_state, row: row}}
    end
  end

  @doc """
  Returns `true` if `record` can be undone by `actor`.

  Named `undoable?` rather than `can_undo?` because Ash's code interface
  already generates `can_undo?/2` for the `undo` action, and that answers a
  different question — whether the actor is *authorized* to call it, not
  whether there is anything to undo.
  """
  @spec undoable?(Ash.Resource.record(), term()) :: boolean()
  def undoable?(record, actor \\ nil), do: match?({:ok, _}, resolve(record, actor))

  @doc """
  Returns the state `record` would rewind to, or `nil` if it cannot be undone.
  """
  @spec undo_target(Ash.Resource.record(), term()) :: atom() | nil
  def undo_target(record, actor \\ nil) do
    case resolve(record, actor) do
      {:ok, %{target: target}} -> target
      {:error, _reason} -> nil
    end
  end

  defp fetch_config(resource) do
    case Info.undo(resource) do
      nil -> {:error, error(:undo_not_enabled, resource)}
      config -> {:ok, config}
    end
  end

  # The `:initial` row has no `from_state`: it records the workflow coming into
  # existence, not a move between states, so there is nowhere to rewind to.
  defp fetch_head(record, resource) do
    case TransitionLogHelpers.head_state_change(record) do
      nil -> {:error, error(:no_history, resource)}
      %{from_state: nil} -> {:error, error(:no_history, resource)}
      row -> {:ok, row}
    end
  end

  # An undo row is reversed by re-applying the transition it undid, so the edge
  # to check is the one it originally came from — read backwards. That is how
  # redo works without a rule of its own.
  defp check_undoable(resource, %{triggered_by: :undo} = row) do
    if Info.undoable_edge?(resource, row.to_state, row.from_state) do
      :ok
    else
      {:error, error(:not_undoable, resource, row)}
    end
  end

  defp check_undoable(resource, row) do
    if Info.undoable_edge?(resource, row.from_state, row.to_state) do
      :ok
    else
      {:error, error(:not_undoable, resource, row)}
    end
  end

  defp check_window(config, row, resource) do
    case UndoConfig.window_seconds(config) do
      nil ->
        :ok

      seconds ->
        if DateTime.diff(DateTime.utc_now(), row.occurred_at, :second) <= seconds do
          :ok
        else
          {:error, error(:window_expired, resource, row)}
        end
    end
  end

  defp check_actor(%UndoConfig{same_actor?: false}, _resource, _row, _actor), do: :ok

  defp check_actor(%UndoConfig{same_actor?: true}, resource, row, actor) do
    log = TransitionLogHelpers.fetch_log!(resource)
    recorded = recorded_actor_id(log, row)

    cond do
      is_nil(recorded) or is_nil(actor) ->
        {:error, error(:no_actor, resource, row)}

      recorded == TransitionLogHelpers.primary_key_value!(actor) ->
        :ok

      true ->
        {:error, error(:different_actor, resource, row)}
    end
  end

  defp recorded_actor_id(log, row) do
    case TransitionLog.belongs_to_actor(log) do
      nil ->
        nil

      belongs_to_actor ->
        foreign_key =
          TransitionLogHelpers.foreign_key_for_relationship!(log.resource, belongs_to_actor.name)

        Map.get(row, foreign_key)
    end
  end

  defp error(reason, resource, row \\ nil) do
    UndoNotPermitted.exception(
      reason: reason,
      resource: resource,
      from_state: row && row.from_state,
      to_state: row && row.to_state
    )
  end
end
