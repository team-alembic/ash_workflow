defmodule AshWorkflow.Transformers.AddActions do
  @moduledoc """
  Generates and modifies Ash actions based on workflow step declarations.

  Adds or modifies the following actions on the resource:

  - **Transition actions** (for manual steps) — one `:update` action per declared
    `transition` entity. Each includes:
    - `BuiltinChanges.transition_state(target)` to move the state
    - `AshWorkflow.Changes.RecordEvent` (`triggered_by: :manual`) to write through
      `state_entered_at` and append a log row if a `transition_log` is configured

  - **Automatic step action injection** — for automatic steps, the user defines
    their own update action with business logic. This transformer finds that action
    by the step's `action` name and appends `transition_state` and
    `RecordEvent` (`triggered_by: :automatic`) changes to it. Raises at compile
    time if the action is not defined on the resource.

  - **Timeout transition actions** — for timeouts with `transition_to`, generates
    a hidden update action named `__timeout_<step>_<name>` that transitions to the
    target state and records the event (`triggered_by: :timeout`).

  - **Undo action** — when the workflow declares an `undo` block, a single
    `:undo` update action that rewinds the record to the state before its most
    recent undoable state change. Not atomic: the target is only known after
    reading the transition log.

  - **Primary read action** — if the workflow has automatic steps (which generate
    Oban triggers) and no primary read action is defined, generates one with
    keyset pagination enabled (required by ash_oban).

  Also adds a resource-global `change RecordEvent, on: [:create]`
  (`triggered_by: :initial`), since workflows are started through the user's
  own create action rather than a generated one — there is no per-action call
  site to inject into for that event.
  """
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Ash.Resource.Dsl, as: ResourceDsl
  alias Ash.Resource.Info, as: ResourceInfo
  alias AshStateMachine.BuiltinChanges
  alias AshWorkflow.Changes.ConditionalOnSuccess
  alias AshWorkflow.Changes.ConditionalTransition
  alias AshWorkflow.Changes.RecordEvent
  alias AshWorkflow.Changes.UndoTransition
  alias AshWorkflow.Entities.Route
  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Entities.Timeout
  alias AshWorkflow.Entities.Transition
  alias AshWorkflow.Info
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  def transform(dsl) do
    steps =
      dsl
      |> Transformer.get_entities([:workflow])
      |> Enum.filter(&match?(%Step{}, &1))

    dsl =
      dsl
      |> add_read_action()
      |> add_initial_event_change()
      |> add_transition_actions(steps)
      |> inject_automatic_step_changes(steps)
      |> add_timeout_actions(steps)
      |> add_on_error_actions(steps)
      |> add_undo_action()

    {:ok, dsl}
  end

  defp add_initial_event_change(dsl) do
    change =
      Transformer.build_entity!(ResourceDsl, [:changes], :change,
        change: {RecordEvent, triggered_by: :initial},
        on: [:create]
      )

    Transformer.add_entity(dsl, [:changes], change)
  end

  defp add_read_action(dsl) do
    if ResourceInfo.primary_action(dsl, :read) != nil do
      dsl
    else
      # Keyset pagination is required by ash_oban. `required?: false` with
      # `paginate_by_default?: true` keeps reads paginated as they always have
      # been, while allowing `page: false` to opt out — Ash's default of
      # `required?: true` makes opting out raise PaginationRequired.
      {:ok, pagination} =
        Builder.build_pagination(
          keyset?: true,
          default_limit: 100,
          required?: false,
          paginate_by_default?: true
        )

      read_action =
        Transformer.build_entity!(ResourceDsl, [:actions], :read,
          name: read_action_name(dsl),
          primary?: true,
          pagination: pagination
        )

      Transformer.add_entity(dsl, [:actions], read_action)
    end
  end

  # ash_oban needs a primary read, and the resource has none. Normally that
  # action is called `:read`, but the name may already be taken by a read that
  # is not primary — `defaults [:read]` produces exactly that, and is not always
  # marked primary by the time this transformer runs. Reusing the name in that
  # case fails the build with "Multiple actions with the name `read` defined".
  defp read_action_name(dsl) do
    if Enum.any?(ResourceInfo.actions(dsl), &(&1.name == :read)) do
      :__workflow_read
    else
      :read
    end
  end

  defp add_transition_actions(dsl, steps) do
    # Collect all transitions grouped by name, tracking which step each came from
    grouped =
      steps
      |> Enum.filter(&Step.manual?/1)
      |> Enum.flat_map(fn step ->
        Enum.map(step.transitions, &{step.name, &1})
      end)
      |> Enum.group_by(fn {_step, t} -> t.name end)

    state_attribute = Info.state_attribute(dsl)

    Enum.reduce(grouped, dsl, fn {name, step_transitions}, dsl ->
      add_transition_action(dsl, name, step_transitions, state_attribute)
    end)
  end

  defp add_transition_action(dsl, name, step_transitions, state_attribute) do
    routes = build_routes_for_transition(step_transitions, state_attribute)
    is_conditional = length(routes) > 1 or has_explicit_routes?(step_transitions)

    accepted =
      step_transitions
      |> Enum.flat_map(fn {_step, t} -> t.accept end)
      |> Enum.uniq()

    transition_changes =
      if is_conditional do
        [
          Transformer.build_entity!(ResourceDsl, [:actions, :update], :change,
            change:
              {ConditionalTransition, routes: routes, transition_name: name, accept: accepted}
          )
        ]
      else
        [route] = routes

        [
          Transformer.build_entity!(ResourceDsl, [:actions, :update], :change,
            change: BuiltinChanges.transition_state(route.to)
          )
        ]
      end

    record_event_change =
      Transformer.build_entity!(ResourceDsl, [:actions, :update], :change,
        change: {RecordEvent, triggered_by: :manual, transition_name: name}
      )

    changes = transition_changes ++ [record_event_change]

    actions = Transformer.get_entities(dsl, [:actions])

    case Enum.find(actions, &(&1.name == name)) do
      nil ->
        opts = [name: name, accept: accepted, changes: changes]
        opts = if is_conditional, do: Keyword.put(opts, :require_atomic?, false), else: opts
        action = Transformer.build_entity!(ResourceDsl, [:actions], :update, opts)
        Transformer.add_entity(dsl, [:actions], action)

      existing_action ->
        merged_accept = Enum.uniq(existing_action.accept ++ accepted)

        updated_action = %{
          existing_action
          | accept: merged_accept,
            changes: existing_action.changes ++ changes
        }

        updated_action =
          if is_conditional,
            do: Map.put(updated_action, :require_atomic?, false),
            else: updated_action

        dsl
        |> Transformer.remove_entity([:actions], &(&1.name == name))
        |> Transformer.add_entity([:actions], updated_action)
    end
  end

  # One action for every undoable edge, rather than one per transition. The
  # rewind target comes from the log row being reversed, so a single action can
  # serve every undoable transition on the resource — including conditional
  # ones, whose forward target was itself only known at runtime.
  defp add_undo_action(dsl) do
    if Info.undo(dsl) do
      action =
        Transformer.build_entity!(ResourceDsl, [:actions], :update,
          name: undo_action_name(),
          accept: [],
          require_atomic?: false,
          changes: [
            Transformer.build_entity!(ResourceDsl, [:actions, :update], :change,
              change: {UndoTransition, []}
            ),
            Transformer.build_entity!(ResourceDsl, [:actions, :update], :change,
              change: {RecordEvent, triggered_by: :undo}
            )
          ]
        )

      Transformer.add_entity(dsl, [:actions], action)
    else
      dsl
    end
  end

  @doc "Name of the generated undo action."
  @spec undo_action_name() :: atom()
  def undo_action_name, do: :undo

  defp build_routes_for_transition(step_transitions, state_attribute) do
    require Ash.Expr

    Enum.flat_map(step_transitions, fn {step_name, transition} ->
      build_step_routes(step_name, transition, state_attribute)
    end)
  end

  defp build_step_routes(step_name, transition, state_attribute) do
    require Ash.Expr

    in_step = Ash.Expr.expr(^Ash.Expr.ref(state_attribute) == ^step_name)

    if Transition.conditional?(transition) do
      Enum.map(transition.routes, fn route ->
        %{route | when: Ash.Expr.expr(^in_step and ^route.when)}
      end)
    else
      [%Route{to: transition.to, when: in_step}]
    end
  end

  defp has_explicit_routes?(step_transitions) do
    Enum.any?(step_transitions, fn {_step, t} ->
      Transition.conditional?(t)
    end)
  end

  defp inject_automatic_step_changes(dsl, steps) do
    steps
    |> Enum.reject(&(Step.manual?(&1) || Step.terminal?(&1)))
    |> Enum.reduce(dsl, fn step, dsl ->
      actions = Transformer.get_entities(dsl, [:actions])

      case Enum.find(actions, &(&1.name == step.action)) do
        nil ->
          # Defensive — verifiers can't catch this since they run after transformers
          raise DslError,
            path: [:workflow, :step, step.name],
            message: missing_action_message(step)

        existing_action ->
          apply_on_success_changes(dsl, step, existing_action)
      end
    end)
  end

  defp apply_on_success_changes(dsl, step, existing_action) do
    {transition_change, conditional?} = build_on_success_change(step)

    record_event_change =
      Transformer.build_entity!(ResourceDsl, [:actions, :update], :change,
        change: {RecordEvent, triggered_by: :automatic}
      )

    updated_action = %{
      existing_action
      | changes: existing_action.changes ++ [transition_change, record_event_change]
    }

    updated_action =
      if conditional?,
        do: Map.put(updated_action, :require_atomic?, false),
        else: updated_action

    dsl
    |> Transformer.remove_entity([:actions], &(&1.name == step.action))
    |> Transformer.add_entity([:actions], updated_action)
  end

  defp build_on_success_change(step) do
    if Step.on_success_conditional?(step) do
      change =
        Transformer.build_entity!(ResourceDsl, [:actions, :update], :change,
          change: {ConditionalOnSuccess, routes: step.on_success, step_name: step.name}
        )

      {change, true}
    else
      target = step.on_success |> List.first() |> then(&(&1 && &1.to))

      change =
        Transformer.build_entity!(ResourceDsl, [:actions, :update], :change,
          change: BuiltinChanges.transition_state(target)
        )

      {change, false}
    end
  end

  defp missing_action_message(%{action: nil} = step) do
    "Step :#{step.name} must either declare an action (automatic step), at least one " <>
      "transition (manual step), or a timeout with transition_to (wait state)."
  end

  defp missing_action_message(step) do
    "Automatic step :#{step.name} references action :#{step.action}, but no such action is defined on the resource."
  end

  # An automatic step's `on_error` target needs an action for AshOban's trigger
  # `on_error` to call. Without one the state machine permits the error
  # transition but nothing ever performs it, so a failing step just stays put
  # and gets retried forever.
  defp add_on_error_actions(dsl, steps) do
    steps
    |> Enum.filter(&(&1.on_error && &1.action))
    |> Enum.reduce(dsl, fn step, dsl ->
      action =
        Transformer.build_entity!(ResourceDsl, [:actions], :update,
          name: on_error_action_name(step),
          accept: [],
          require_atomic?: false,
          changes: [
            Transformer.build_entity!(ResourceDsl, [:actions, :update], :change,
              change: BuiltinChanges.transition_state(step.on_error)
            ),
            Transformer.build_entity!(ResourceDsl, [:actions, :update], :change,
              change: {RecordEvent, triggered_by: :error_path, transition_name: step.action}
            )
          ]
        )

      Transformer.add_entity(dsl, [:actions], action)
    end)
  end

  @doc false
  def on_error_action_name(%{name: name}), do: :"__on_error_#{name}"

  @doc """
  Name of the hidden action a transition timeout performs.

  Scoped by step so the same timeout name can be used on more than one step,
  the way transition names can.
  """
  def timeout_action_name(step, timeout), do: :"__timeout_#{step.name}_#{timeout.name}"

  defp add_timeout_actions(dsl, steps) do
    dsl =
      steps
      |> Enum.flat_map(fn step ->
        step.timeouts
        |> Enum.filter(& &1.transition_to)
        |> Enum.map(fn timeout -> {step, timeout} end)
      end)
      |> Enum.reduce(dsl, fn {step, timeout}, dsl ->
        action_name = timeout_action_name(step, timeout)

        action =
          Transformer.build_entity!(ResourceDsl, [:actions], :update,
            name: action_name,
            changes: [
              Transformer.build_entity!(ResourceDsl, [:actions, :update], :change,
                change: BuiltinChanges.transition_state(timeout.transition_to)
              ),
              Transformer.build_entity!(ResourceDsl, [:actions, :update], :change,
                change: {RecordEvent, triggered_by: :timeout, transition_name: timeout.name}
              )
            ]
          )

        Transformer.add_entity(dsl, [:actions], action)
      end)

    inject_action_timeout_changes(dsl, steps)
  end

  # Every timeout that names an action gets `RecordEvent`, repeating or not: a
  # one-shot reminder is a workflow event, and the log's contract is one row
  # per event. Two timeouts may name the same action, so the actions are
  # deduplicated before the change is appended, and the action resets
  # `state_entered_at` if any timeout naming it repeats.
  defp inject_action_timeout_changes(dsl, steps) do
    steps
    |> Enum.flat_map(fn step ->
      step.timeouts
      |> Enum.filter(&(&1.action != nil))
      |> Enum.map(&{step, &1})
    end)
    |> Enum.group_by(fn {_step, timeout} -> timeout.action end)
    |> Enum.map(fn {_action, pairs} ->
      {step, timeout} = hd(pairs)
      {step, timeout, Enum.any?(pairs, fn {_step, timeout} -> Timeout.repeats?(timeout) end)}
    end)
    |> Enum.reduce(dsl, fn {step, timeout, repeats?}, dsl ->
      actions = Transformer.get_entities(dsl, [:actions])

      case Enum.find(actions, &(&1.name == timeout.action)) do
        nil ->
          raise DslError,
            path: [:workflow, :step, step.name],
            message:
              "Timeout :#{timeout.name} on step :#{step.name} references action :#{timeout.action}, but no such action is defined on the resource."

        existing_action ->
          record_event_change =
            Transformer.build_entity!(ResourceDsl, [:actions, :update], :change,
              change: {
                RecordEvent,
                triggered_by: :timeout, touch_state_entered_at: repeats?, repeat_fire?: repeats?
              }
            )

          updated_action = %{
            existing_action
            | changes: existing_action.changes ++ [record_event_change]
          }

          dsl
          |> Transformer.remove_entity([:actions], &(&1.name == timeout.action))
          |> Transformer.add_entity([:actions], updated_action)
      end
    end)
  end

  # Expands `defaults [...]` into real actions and marks primaries. Running
  # before it means asking whether a primary read exists while the answer is
  # still being decided, which is how this transformer used to generate a
  # second action named `:read`.
  def after?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def after?(_), do: false

  def before?(AshStateMachine.Transformers.FillInTransitionDefaults), do: true
  def before?(AshStateMachine.Transformers.AddState), do: true
  def before?(AshStateMachine.Transformers.EnsureStateSelected), do: true
  def before?(AshOban.Transformers.SetDefaults), do: true
  def before?(AshOban.Transformers.DefineSchedulers), do: true
  def before?(AshOban.Transformers.DefineActionWorkers), do: true
  def before?(_), do: false
end
