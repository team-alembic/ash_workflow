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
      `:timeout`, `:error_path`, `:undo`.
    * `:transition_name` (optional) — the name recorded on the log row.
      Defaults to `changeset.action.name`, which is enough for most sites, but
      several of the actions `AddActions` generates use an internal hidden
      name (e.g. `__on_error_process`) that would be confusing in history, so
      those sites pass a human-facing name explicitly. An undo takes the name
      of the row it reverses, so the pair reads as one decision and its
      reversal rather than as two unrelated events.

  ## Undo

  `AshWorkflow.Changes.UndoTransition` puts the row being reversed into the
  changeset context, and this change writes its primary key to the log's
  `undoes` foreign key. That pointer is what makes an undo additive: the
  reversed row is left exactly as written, and both readings of history stay
  derivable from the same rows — see `AshWorkflow.TransitionLog.effective/1`.

  ## Telemetry

  This change is also where the `[:ash_workflow, :transition]` span is emitted,
  for the same reason it is where the log row is written: it runs on every
  action AshWorkflow generates, so one place covers a manual transition, an
  automatic step, a timeout, an error path, an undo and the initial create. See
  `AshWorkflow.Telemetry` for the events and their metadata.

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
  alias AshWorkflow.Telemetry
  alias AshWorkflow.TransitionLog, as: TransitionLogHelpers

  @triggered_by_values [:initial, :manual, :automatic, :timeout, :error_path, :undo]

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
    |> emit_start(opts)
    |> Ash.Changeset.after_action(fn changeset, record ->
      {:ok, finish(changeset, record, opts, context)}
    end)
  end

  @impl true
  def atomic(changeset, opts, context) do
    changeset =
      changeset
      |> emit_start(opts)
      |> Ash.Changeset.after_action(fn changeset, record ->
        {:ok, finish(changeset, record, opts, context)}
      end)

    {:atomic, changeset, %{state_entered_at: expr(now())}}
  end

  defp finish(changeset, record, opts, context) do
    record = append_log(changeset, record, opts, context)

    emit_stop(changeset, record)

    record
  end

  # The span opens here rather than in the after_action hook because this is
  # where the action begins: `change/3` and `atomic/3` both run while the
  # changeset is being built, before the data layer is touched.
  defp emit_start(changeset, opts) do
    metadata = %{
      resource: changeset.resource,
      workflow_id: workflow_id(changeset),
      from_state: telemetry_from_state(changeset),
      to_state: declared_to_state(changeset),
      action: changeset.action.name,
      transition_name: opts[:transition_name] || changeset.action.name,
      triggered_by: opts[:triggered_by]
    }

    Ash.Changeset.put_context(changeset, :ash_workflow_telemetry, %{
      metadata: metadata,
      started_at: Telemetry.transition_start(metadata)
    })
  end

  defp emit_stop(changeset, record) do
    case changeset.context[:ash_workflow_telemetry] do
      %{metadata: metadata, started_at: started_at} ->
        state_attribute = AshStateMachine.Info.state_machine_state_attribute!(changeset.resource)

        metadata = %{
          metadata
          | to_state: Map.get(record, state_attribute, metadata.to_state),
            workflow_id: metadata.workflow_id || record_workflow_id(record)
        }

        Telemetry.transition_stop(metadata, started_at)

      _no_span ->
        :ok
    end
  end

  # The declared target, which a conditional transition does not have: its
  # route is chosen at runtime by `AshWorkflow.Changes.ConditionalTransition`.
  # The `:stop` event carries the state the record actually landed in.
  defp declared_to_state(changeset) do
    changeset.resource
    |> AshStateMachine.Info.state_machine_transitions()
    |> Enum.filter(&(&1.action == changeset.action.name))
    |> case do
      [%{to: [to]}] -> to
      _many_or_none -> nil
    end
  end

  # Unlike the log's `from_state/5`, this does not fall back to reading the last
  # logged row. A span must not add a query, and telemetry is available whether
  # or not a transition log is configured.
  defp telemetry_from_state(%{action_type: :create}), do: nil

  defp telemetry_from_state(changeset) do
    state_attribute = AshStateMachine.Info.state_machine_state_attribute!(changeset.resource)

    case Map.get(changeset.data, state_attribute) do
      %Ash.NotLoaded{} -> nil
      state -> state
    end
  end

  # Read straight off `changeset.data` rather than through
  # `Ash.Changeset.get_attribute/2`, which raises "Original data is not
  # available" on an atomic changeset. A create has no data yet, so the id is
  # nil on `:start` and present on `:stop`, which reads from the record.
  defp workflow_id(changeset) do
    case Ash.Resource.Info.primary_key(changeset.resource) do
      [key] -> data_attribute(changeset, key)
      keys -> Map.new(keys, &{&1, data_attribute(changeset, &1)})
    end
  end

  defp data_attribute(%{data: data}, key) when is_struct(data) do
    case Map.get(data, key) do
      %Ash.NotLoaded{} -> nil
      value -> value
    end
  end

  defp data_attribute(_changeset, _key), do: nil

  defp record_workflow_id(record) do
    case Ash.Resource.Info.primary_key(record.__struct__) do
      [key] -> Map.get(record, key)
      keys -> Map.new(keys, &{&1, Map.get(record, &1)})
    end
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

    undone_row = undone_row(changeset)

    attrs = %{
      foreign_key => TransitionLogHelpers.primary_key_value!(record),
      from_state: from_state(changeset, state_attribute, log, foreign_key, record),
      to_state: Map.get(record, state_attribute),
      transition_name: transition_name(undone_row, opts, changeset),
      occurred_at: DateTime.utc_now(),
      triggered_by: opts[:triggered_by]
    }

    attrs = put_undoes(attrs, log, undone_row)

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

  defp undone_row(changeset) do
    changeset.context
    |> Map.get(:ash_workflow, %{})
    |> Map.get(:undoes)
  end

  defp transition_name(nil, opts, changeset), do: opts[:transition_name] || changeset.action.name
  defp transition_name(undone_row, _opts, _changeset), do: undone_row.transition_name

  defp put_undoes(attrs, _log, nil), do: attrs

  defp put_undoes(attrs, log, undone_row) do
    case TransitionLogHelpers.undoes_foreign_key(log.resource) do
      nil ->
        attrs

      foreign_key ->
        Map.put(attrs, foreign_key, TransitionLogHelpers.primary_key_value!(undone_row))
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
