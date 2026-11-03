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
      `:timeout`, `:error_path`, `:undo`, `:signal`.
    * `:touch_state_entered_at` (optional, defaults to `true`) — whether the
      change writes `state_entered_at`. A timeout must not reset it, because
      every other deadline on the step measures `after` from the same
      attribute, so moving it would push a pending `transition_to` timeout out
      of reach. An `every`'s own firing does not reset it either — see
      `:every_field` below — so this is `true` only for a genuine step entry:
      a manual transition, an automatic step completion, a transition
      timeout, an undo and the initial create.
    * `:every_field` (optional, defaults to `nil`) — the attribute an
      `every`'s firing writes its last-fired instant to, named by
      `AshWorkflow.Entities.Every.last_fired_field/2`. Set only on the change
      `AshWorkflow.Transformers.AddActions` injects into an `every`'s action,
      this is how that firing re-arms its own trigger for the next interval
      without touching `state_entered_at`, which every other deadline on the
      step measures from.
    * `:every_fires_field` (optional, defaults to `nil`) — the integer attribute
      counting the `every`'s fires in the current step visit, named by
      `AshWorkflow.Entities.Every.fires_field/2`. Incremented on each fire, and
      restarted at 1 when `:every_field` holds a fire from before
      `state_entered_at`, which belongs to an earlier visit.
    * `:timeout_fields` (optional, defaults to `%{}`) — the columns an action
      timeout's firing writes, as a map from step name to the
      `AshWorkflow.Entities.Timeout.fired_field/2` columns of that step's
      timeouts that run this action. Only the current step's columns are
      written. Set only on the change `AshWorkflow.Transformers.AddActions`
      injects into an action timeout's action. An action timeout does not
      change state, so this write is what stops it matching again. See
      `AshWorkflow.Scheduler.Work.not_fired/1` for the guard that reads it.
    * `:transition_name` (optional) — the name recorded on the log row.
      Defaults to `changeset.action.name`, which is enough for most sites, but
      several of the actions `AddActions` generates use an internal hidden
      name (e.g. `__on_error_process`) that would be confusing in history, so
      those sites pass a human-facing name explicitly. An undo takes the name
      of the row it reverses, so the pair reads as one decision and its
      reversal rather than as two unrelated events.
    * `:emits` (optional, defaults to `[]`) — the workflow signals this change
      may emit, set by `AshWorkflow.Transformers.AddActions` when the workflow
      names a `signals` module. Each entry is a map with `:signal`, `:fields`,
      `:values` and `:when`, where `:when` is `:state_change`, `{:enter, step}`,
      `{:exit, step}`, `{:from, step}` or `:always`.

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

  ## Signals

  When the workflow names a `signals` module, this change emits the `:emits`
  entries that match the event with `Ash.Signals.emit/5`, in the same
  `after_action` hook as the log append. A listener error fails the action and
  rolls it back. On an atomic update of an action with several `from` states
  and no transition log, the from state is unknown, so `on: :exit`,
  transition, timeout and `every` emits do not fire.

  ## Telling the scheduler

  Entering a step is when the deadlines ahead of a record become known, so this
  change also calls `AshWorkflow.Scheduler.notify_state_change/2`. A scheduler
  that arms timers needs that call to be precise. A scheduler that polls uses
  it to run an automatic step as soon as a record enters it. A step's action
  that routes the record back into the same step does not count as entering
  it, so a polling scheduler leaves that record for its next poll.

  It runs in the same `after_action` hook as the log append and the span's stop
  event, which means it runs after the data layer has committed the new state.
  A timer armed before the commit could fire against a record still holding the
  old state.

  ## Upserts

  A create action that upserts onto an existing row leaves that row in the
  step it was in. This change writes no log row for it, emits no signal and
  does not call `AshWorkflow.Scheduler.notify_state_change/2`. The telemetry
  span still opens and closes, because its `:start` event fires before the
  data layer reports whether the row was inserted.

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
  alias AshWorkflow.Scheduler
  alias AshWorkflow.Telemetry
  alias AshWorkflow.TransitionLog, as: TransitionLogHelpers

  @triggered_by_values [:initial, :manual, :automatic, :timeout, :error_path, :undo, :signal]

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
    |> touch_state_entered_at(opts)
    |> touch_fired_fields(opts)
    |> touch_fires_field(opts)
    |> emit_start(opts)
    |> Ash.Changeset.after_action(&finish(&1, &2, opts, context))
  end

  @impl true
  def atomic(changeset, opts, context) do
    changeset =
      changeset
      |> emit_start(opts)
      |> Ash.Changeset.after_action(&finish(&1, &2, opts, context))

    {:atomic, changeset, atomic_touched_attrs(changeset, opts)}
  end

  defp atomic_touched_attrs(changeset, opts) do
    attrs =
      if touch_state_entered_at?(opts), do: %{state_entered_at: expr(now())}, else: %{}

    changeset
    |> fired_fields(opts)
    |> Enum.reduce(attrs, &Map.put(&2, &1, expr(now())))
    |> put_atomic_fires(opts)
  end

  defp touch_state_entered_at(changeset, opts) do
    if touch_state_entered_at?(opts) do
      Ash.Changeset.force_change_attribute(changeset, :state_entered_at, DateTime.utc_now())
    else
      changeset
    end
  end

  defp touch_fired_fields(changeset, opts) do
    now = DateTime.utc_now()

    changeset
    |> fired_fields(opts)
    |> Enum.reduce(changeset, &Ash.Changeset.force_change_attribute(&2, &1, now))
  end

  defp touch_fires_field(changeset, opts) do
    case every_fires_field(opts) do
      nil ->
        changeset

      fires_field ->
        last_fired_at = data_attribute(changeset, every_field(opts))
        state_entered_at = data_attribute(changeset, :state_entered_at)

        fires =
          if this_visit?(last_fired_at, state_entered_at),
            do: (data_attribute(changeset, fires_field) || 0) + 1,
            else: 1

        Ash.Changeset.force_change_attribute(changeset, fires_field, fires)
    end
  end

  defp this_visit?(nil, _state_entered_at), do: false
  defp this_visit?(_last_fired_at, nil), do: true

  defp this_visit?(last_fired_at, state_entered_at),
    do: DateTime.compare(last_fired_at, state_entered_at) != :lt

  # Attribute references in an atomic update read the row as it was before the
  # update, so this compares the previous fire against the current visit.
  defp put_atomic_fires(attrs, opts) do
    case every_fires_field(opts) do
      nil ->
        attrs

      fires_field ->
        last_fired_at = Ash.Expr.ref(every_field(opts))
        fires = Ash.Expr.ref(fires_field)

        Map.put(
          attrs,
          fires_field,
          expr(
            if not is_nil(^last_fired_at) and ^last_fired_at >= state_entered_at do
              ^fires + 1
            else
              1
            end
          )
        )
    end
  end

  defp fired_fields(changeset, opts) do
    List.wrap(every_field(opts)) ++ timeout_fields(changeset, opts)
  end

  # Two timeouts on different steps may share an action, and only the step the
  # record is in has fired. When the changeset's data does not hold the state,
  # every step's columns are written. A column written for a step the record is
  # not in skips that timeout on a later visit only if its deadline has already
  # passed on entry. A column left unwritten fires the timeout on every poll.
  defp timeout_fields(changeset, opts) do
    fields_by_step = Keyword.get(opts, :timeout_fields, %{})

    if fields_by_step == %{} do
      []
    else
      state_attribute = AshStateMachine.Info.state_machine_state_attribute!(changeset.resource)

      case data_attribute(changeset, state_attribute) do
        nil -> fields_by_step |> Map.values() |> List.flatten() |> Enum.uniq()
        state -> Map.get(fields_by_step, state, [])
      end
    end
  end

  defp touch_state_entered_at?(opts), do: Keyword.get(opts, :touch_state_entered_at, true)

  defp every_field(opts), do: Keyword.get(opts, :every_field)

  defp every_fires_field(opts), do: Keyword.get(opts, :every_fires_field)

  # The `:start` event fired before the data layer reported whether the create
  # inserted, so the span still closes on an upsert that entered no step.
  defp finish(changeset, record, opts, context) do
    if upserted_onto_existing_row?(changeset, record) do
      emit_stop(changeset, record)
      {:ok, record}
    else
      record_entry(changeset, record, opts, context)
    end
  end

  # Signals go out after the log row so a listener that reads history sees this
  # event, and before the span closes so a failing listener's error is what the
  # span and the scheduler see: neither runs for an event that rolls back.
  defp record_entry(changeset, record, opts, context) do
    log = Info.transition_log(changeset.resource)
    plan = Keyword.get(opts, :emits, [])
    from_state = event_from_state(changeset, record, log, plan, opts)

    append_log(changeset, record, log, from_state, opts, context)

    case emit_signals(changeset, record, plan, from_state, opts) do
      :ok ->
        emit_stop(changeset, record)

        Scheduler.notify_state_change(record,
          entered_step?: entered_step?(changeset, record, opts)
        )

        {:ok, record}

      {:error, error} ->
        rollback(changeset.resource, error)
    end
  end

  # Ash's atomic upgrade of a single update returns an `after_action` error
  # without rolling back its transaction, so the state change would commit.
  defp rollback(resource, error) do
    if Ash.DataLayer.in_transaction?(resource) do
      Ash.DataLayer.rollback(resource, error)
    else
      {:error, error}
    end
  end

  defp emit_signals(_changeset, _record, [], _from_state, _opts), do: :ok

  defp emit_signals(changeset, record, plan, from_state, opts) do
    signals = Info.signals(changeset.resource)
    to_state = record_state(record)

    workflow_fields = %{
      from_state: from_state,
      to_state: to_state,
      transition_name: transition_name(undone_row(changeset), opts, changeset),
      triggered_by: opts[:triggered_by],
      occurred_at: DateTime.utc_now()
    }

    plan
    |> Enum.filter(&emit?(&1.when, from_state, to_state))
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      payload = signal_payload(signals, entry, record, workflow_fields)

      case Ash.Signals.emit(changeset, signals, entry.signal, payload) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp emit?(:always, _from_state, _to_state), do: true
  defp emit?(:state_change, _from_state, _to_state), do: true
  defp emit?({:enter, step}, _from_state, to_state), do: to_state == step
  defp emit?({:exit, step}, from_state, _to_state), do: from_state == step
  defp emit?({:from, step}, from_state, _to_state), do: from_state == step

  defp signal_payload(signals, entry, record, workflow_fields) do
    names =
      signals
      |> Ash.Signals.Info.signal(entry.signal)
      |> Map.get(:arguments)
      |> Enum.map(& &1.name)

    attributes = record.__struct__ |> Ash.Resource.Info.attributes() |> MapSet.new(& &1.name)

    workflow = Map.take(workflow_fields, names)

    same_name =
      for name <- names, MapSet.member?(attributes, name), into: %{} do
        {name, Map.get(record, name)}
      end

    mapped =
      Map.new(entry.fields, fn {signal_field, attribute} ->
        {signal_field, Map.get(record, attribute)}
      end)

    workflow
    |> Map.merge(same_name)
    |> Map.merge(mapped)
    |> Map.merge(Map.new(entry.values))
    |> Map.take(names)
  end

  defp record_state(record) do
    Map.get(record, AshStateMachine.Info.state_machine_state_attribute!(record.__struct__))
  end

  # A create that upserts onto an existing row leaves it in the step it was in,
  # whether the row was updated or the `upsert_condition` skipped the update.
  defp upserted_onto_existing_row?(%{action_type: :create}, %{
         __metadata__: %{upsert_action: :update}
       }),
       do: true

  defp upserted_onto_existing_row?(%{action_type: :create}, %{
         __metadata__: %{upsert_skipped: true}
       }),
       do: true

  defp upserted_onto_existing_row?(_changeset, _record), do: false

  defp entered_step?(changeset, record, opts) do
    touch_state_entered_at?(opts) and not stayed_in_step?(changeset, record)
  end

  # An action whose every declared transition starts in the step the record now
  # occupies cannot have moved it there: that is a step routing back to itself.
  # Read from the declared transitions rather than `changeset.data`, which an
  # atomic update from an AshOban worker does not hold.
  defp stayed_in_step?(changeset, record) do
    state_attribute = AshStateMachine.Info.state_machine_state_attribute!(changeset.resource)

    from_states =
      changeset.resource
      |> AshStateMachine.Info.state_machine_transitions()
      |> Enum.filter(&(&1.action == changeset.action.name))
      |> Enum.flat_map(&List.wrap(&1.from))
      |> Enum.uniq()

    from_states == [Map.get(record, state_attribute)]
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

  defp append_log(_changeset, _record, nil, _from_state, _opts, _context), do: :ok

  defp append_log(changeset, record, log, from_state, opts, context) do
    attrs = build_log_attrs(changeset, record, log, from_state, opts, context)

    log.resource
    |> Ash.Changeset.for_create(:create, attrs, actor: context.actor, authorize?: false)
    |> Ash.create!()

    :ok
  end

  defp build_log_attrs(changeset, record, log, from_state, opts, context) do
    workflow_resource = changeset.resource
    foreign_key = TransitionLogHelpers.foreign_key!(log.resource, workflow_resource)
    state_attribute = AshStateMachine.Info.state_machine_state_attribute!(workflow_resource)

    undone_row = undone_row(changeset)

    attrs = %{
      foreign_key => TransitionLogHelpers.primary_key_value!(record),
      from_state: from_state,
      to_state: Map.get(record, state_attribute),
      transition_name: transition_name(undone_row, opts, changeset),
      occurred_at: DateTime.utc_now(),
      triggered_by: opts[:triggered_by]
    }

    attrs = put_undoes(attrs, log, undone_row)

    case TransitionLog.recorded_actor(log, context.actor) do
      nil ->
        attrs

      actor ->
        actor_foreign_key =
          TransitionLogHelpers.foreign_key_for_relationship!(
            log.resource,
            TransitionLog.belongs_to_actor(log).name
          )

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

  defp event_from_state(_changeset, _record, nil, [], _opts), do: nil
  defp event_from_state(%{action_type: :create}, _record, _log, _plan, _opts), do: nil

  defp event_from_state(changeset, record, log, _plan, opts) do
    state_attribute = AshStateMachine.Info.state_machine_state_attribute!(changeset.resource)

    # An event that does not change state, such as an action timeout or an
    # `every` firing, left the record in the state it started in.
    if touch_state_entered_at?(opts) do
      data_attribute(changeset, state_attribute) || declared_from_state(changeset) ||
        last_logged_state(log, record)
    else
      Map.get(record, state_attribute)
    end
  end

  # An atomic update has no `data` to read the pre-update state from, and a
  # partially selected record has the attribute unloaded. Both are the normal
  # case for AshOban-driven steps and timeouts. An action with a single `from`
  # state names it; otherwise the last logged row landed in the state this
  # transition is leaving.
  defp declared_from_state(changeset) do
    changeset.resource
    |> AshStateMachine.Info.state_machine_transitions()
    |> Enum.filter(&(&1.action == changeset.action.name))
    |> case do
      [%{from: [from]}] when from != :* -> from
      _many_or_none -> nil
    end
  end

  defp last_logged_state(nil, _record), do: nil

  defp last_logged_state(log, record) do
    foreign_key = TransitionLogHelpers.foreign_key!(log.resource, record.__struct__)

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
