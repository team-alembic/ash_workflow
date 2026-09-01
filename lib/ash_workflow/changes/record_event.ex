defmodule AshWorkflow.Changes.RecordEvent do
  @moduledoc """
  Records a workflow event: writes through `state_entered_at` and, if a
  `transition_log` is configured, appends one row describing what happened.

  Replaces the five copy-pasted `set_attribute(:state_entered_at, ...)` call
  sites `AshWorkflow.Transformers.AddActions` used to inject — one per kind of
  workflow event — plus the resource-global `:initial` row on create. The
  change is always injected regardless of whether logging is configured; the
  log append is a single conditional at the leaf, not a fork in the
  transformer.

  ## Options

    * `:triggered_by` (required) — one of `:initial`, `:manual`, `:automatic`,
      `:timeout`, `:error_path`.
    * `:transition_name` (optional) — the name recorded on the log row.
      Defaults to `changeset.action.name`, which is enough for most sites, but
      several of the actions `AddActions` generates use an internal hidden
      name (e.g. `__on_error_process`) that would be confusing in history, so
      those sites pass a human-facing name explicitly.

  ## Atomicity

  This change implements `atomic/3` rather than falling back to
  `require_atomic? false`. `state_entered_at` is set with the `now()` Ash
  expression so it stays part of the atomic update, and the log append is
  attached as an `after_action` hook either way — hooks run after the data
  layer action completes whether or not the attribute update itself was
  atomic, so there is nothing about appending the log row that requires
  opting out of atomicity. This is the "try atomic first" route the design
  doc calls out as the likeliest source of bugs; see
  `test/ash_workflow/changes/record_event_test.exs` for the direct atomicity
  test it asks for.
  """
  use Ash.Resource.Change

  alias AshWorkflow.Entities.TransitionLog
  alias AshWorkflow.Info
  alias AshWorkflow.TransitionLog, as: TransitionLogHelpers

  @triggered_by_values [:initial, :manual, :automatic, :timeout, :error_path]

  @impl true
  @spec init(Keyword.t()) :: {:ok, Keyword.t()} | {:error, String.t()}
  def init(opts) do
    if opts[:triggered_by] in @triggered_by_values do
      {:ok, opts}
    else
      {:error,
       "expected :triggered_by to be one of #{inspect(@triggered_by_values)}, got: #{inspect(opts[:triggered_by])}"}
    end
  end

  @impl true
  def change(changeset, opts, context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:state_entered_at, DateTime.utc_now())
    |> Ash.Changeset.after_action(fn changeset, record ->
      {:ok, append_log(changeset, record, opts, context)}
    end)
  end

  @impl true
  def atomic(changeset, opts, context) do
    changeset =
      Ash.Changeset.after_action(changeset, fn changeset, record ->
        {:ok, append_log(changeset, record, opts, context)}
      end)

    {:atomic, changeset, %{state_entered_at: expr(now())}}
  end

  defp append_log(changeset, record, opts, context) do
    case Info.transition_log(changeset.resource) do
      nil ->
        record

      log ->
        attrs = build_log_attrs(changeset, record, log, opts, context)

        log.resource
        |> Ash.Changeset.for_create(:create, attrs, actor: context.actor, authorize?: false)
        |> Ash.create!()

        record
    end
  end

  defp build_log_attrs(changeset, record, log, opts, context) do
    workflow_resource = changeset.resource
    foreign_key = TransitionLogHelpers.foreign_key!(log.resource, workflow_resource)
    state_attribute = AshStateMachine.Info.state_machine_state_attribute!(workflow_resource)

    attrs = %{
      foreign_key => TransitionLogHelpers.primary_key_value!(record),
      from_state: from_state(changeset, state_attribute, log, foreign_key, record),
      to_state: Map.get(record, state_attribute),
      transition_name: opts[:transition_name] || changeset.action.name,
      occurred_at: DateTime.utc_now(),
      triggered_by: opts[:triggered_by]
    }

    case {TransitionLog.belongs_to_actor(log), context.actor} do
      {nil, _actor} ->
        attrs

      {_belongs_to_actor, nil} ->
        attrs

      {belongs_to_actor, actor} ->
        actor_foreign_key =
          TransitionLogHelpers.foreign_key_for_relationship!(log.resource, belongs_to_actor.name)

        Map.put(attrs, actor_foreign_key, TransitionLogHelpers.primary_key_value!(actor))
    end
  end

  defp from_state(%{action_type: :create}, _state_attribute, _log, _foreign_key, _record), do: nil

  defp from_state(changeset, state_attribute, log, foreign_key, record) do
    # An atomic update has no `data` to read the pre-update state from — it acts
    # on a query, not a loaded record — and a partially selected record has the
    # attribute unloaded. Both are the normal case for AshOban-driven steps and
    # timeouts, which is most events on a busy workflow. Fall back to the state
    # the last logged row landed in: every event is logged, so that is the state
    # this transition is leaving.
    case Map.get(changeset.data, state_attribute) do
      nil -> last_logged_state(log, foreign_key, record)
      %Ash.NotLoaded{} -> last_logged_state(log, foreign_key, record)
      state -> state
    end
  end

  defp last_logged_state(log, foreign_key, record) do
    log.resource
    |> Ash.Query.do_filter([{foreign_key, TransitionLogHelpers.primary_key_value!(record)}])
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [row] -> row.to_state
      [] -> nil
    end
  end
end
