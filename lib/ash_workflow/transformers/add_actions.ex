defmodule AshWorkflow.Transformers.AddActions do
  @moduledoc """
  Generates and modifies Ash actions based on workflow step declarations.

  Adds or modifies the following actions on the resource:

  - **`:start` create action** — creates a new workflow instance. Includes a change
    that sets `state_entered_at` to the current time. The initial state is set by
    ash_state_machine's `default_initial_state`.

  - **Transition actions** (for manual steps) — one `:update` action per declared
    `transition` entity. Each includes:
    - `AshStateMachine.BuiltinChanges.transition_state(target)` to move the state
    - `set_attribute(:state_entered_at, &DateTime.utc_now/0)` to track when the
      new state was entered

  - **Automatic step action injection** — for automatic steps, the user defines
    their own update action with business logic. This transformer finds that action
    by the step's `action` name and appends `transition_state` and
    `state_entered_at` changes to it. Raises at compile time if the action is not
    defined on the resource.

  - **Timeout transition actions** — for timeouts with `transition_to`, generates
    a hidden update action named `__timeout_<name>` that transitions to the target
    state and updates `state_entered_at`.

  - **Primary read action** — if the workflow has automatic steps (which generate
    Oban triggers) and no primary read action is defined, generates one with
    keyset pagination enabled (required by ash_oban).
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  def transform(dsl) do
    steps = Transformer.get_entities(dsl, [:workflow])

    dsl =
      dsl
      |> add_read_action()
      |> add_start_action(steps)
      |> add_transition_actions(steps)
      |> inject_automatic_step_changes(steps)
      |> add_timeout_actions(steps)

    {:ok, dsl}
  end

  defp add_read_action(dsl) do
    cond do
      Ash.Resource.Info.primary_action(dsl, :read) != nil ->
        dsl

      true ->
        # Required for ash_oban triggers and atomic update operations
        {:ok, pagination} =
          Ash.Resource.Builder.build_pagination(keyset?: true, default_limit: 100)

        read_action =
          Transformer.build_entity!(Ash.Resource.Dsl, [:actions], :read,
            name: :read,
            primary?: true,
            pagination: pagination
          )

        Transformer.add_entity(dsl, [:actions], read_action)
    end
  end

  defp add_start_action(dsl, _steps) do
    # Accept all writable attributes so callers can pass resource fields
    accepted_attrs =
      dsl
      |> Ash.Resource.Info.attributes()
      |> Enum.filter(& &1.writable?)
      |> Enum.reject(& &1.primary_key?)
      |> Enum.map(& &1.name)
      |> Enum.reject(&(&1 in [:state, :state_entered_at]))

    start_action =
      Transformer.build_entity!(Ash.Resource.Dsl, [:actions], :create,
        name: :start,
        accept: accepted_attrs,
        changes: [
          Transformer.build_entity!(Ash.Resource.Dsl, [:actions, :create], :change,
            change:
              Ash.Resource.Change.Builtins.set_attribute(:state_entered_at, &DateTime.utc_now/0)
          )
        ]
      )

    Transformer.add_entity(dsl, [:actions], start_action)
  end

  defp add_transition_actions(dsl, steps) do
    # Collect all transitions grouped by name, tracking which step each came from
    grouped =
      steps
      |> Enum.filter(& &1.manual)
      |> Enum.flat_map(fn step ->
        Enum.map(step.transitions, &{step.name, &1})
      end)
      |> Enum.group_by(fn {_step, t} -> t.name end)

    Enum.reduce(grouped, dsl, fn {name, step_transitions}, dsl ->
      add_transition_action(dsl, name, step_transitions)
    end)
  end

  defp add_transition_action(dsl, name, step_transitions) do
    routes = build_routes_for_transition(step_transitions)
    is_conditional = length(routes) > 1 or has_explicit_routes?(step_transitions)

    transition_changes =
      if is_conditional do
        [
          Transformer.build_entity!(Ash.Resource.Dsl, [:actions, :update], :change,
            change:
              {AshWorkflow.Changes.ConditionalTransition, routes: routes, transition_name: name}
          )
        ]
      else
        [route] = routes

        [
          Transformer.build_entity!(Ash.Resource.Dsl, [:actions, :update], :change,
            change: AshStateMachine.BuiltinChanges.transition_state(route.to)
          )
        ]
      end

    timestamp_change =
      Transformer.build_entity!(Ash.Resource.Dsl, [:actions, :update], :change,
        change: Ash.Resource.Change.Builtins.set_attribute(:state_entered_at, &DateTime.utc_now/0)
      )

    changes = transition_changes ++ [timestamp_change]
    actions = Transformer.get_entities(dsl, [:actions])

    case Enum.find(actions, &(&1.name == name)) do
      nil ->
        opts = [name: name, changes: changes]
        opts = if is_conditional, do: Keyword.put(opts, :require_atomic?, false), else: opts
        action = Transformer.build_entity!(Ash.Resource.Dsl, [:actions], :update, opts)
        Transformer.add_entity(dsl, [:actions], action)

      existing_action ->
        updated_action = %{existing_action | changes: existing_action.changes ++ changes}

        updated_action =
          if is_conditional,
            do: Map.put(updated_action, :require_atomic?, false),
            else: updated_action

        dsl
        |> Transformer.remove_entity([:actions], &(&1.name == name))
        |> Transformer.add_entity([:actions], updated_action)
    end
  end

  defp build_routes_for_transition(step_transitions) do
    # For each (step_name, transition) pair, build routes.
    # - A transition with explicit routes keeps them as-is
    # - A static transition from one step = one route
    # - Same-named static transitions from different steps = routes keyed on state
    require Ash.Expr

    step_transitions
    |> Enum.flat_map(fn {step_name, transition} ->
      if AshWorkflow.Entities.Transition.conditional?(transition) do
        transition.routes
      else
        [%AshWorkflow.Entities.Route{to: transition.to, when: Ash.Expr.expr(state == ^step_name)}]
      end
    end)
  end

  defp has_explicit_routes?(step_transitions) do
    Enum.any?(step_transitions, fn {_step, t} ->
      AshWorkflow.Entities.Transition.conditional?(t)
    end)
  end

  defp inject_automatic_step_changes(dsl, steps) do
    steps
    |> Enum.reject(&(&1.manual || &1.terminal))
    |> Enum.reduce(dsl, fn step, dsl ->
      actions = Transformer.get_entities(dsl, [:actions])

      case Enum.find(actions, &(&1.name == step.action)) do
        nil ->
          # Defensive — verifiers can't catch this since they run after transformers
          raise Spark.Error.DslError,
            path: [:workflow, :step, step.name],
            message:
              "Automatic step :#{step.name} references action :#{step.action}, but no such action is defined on the resource."

        existing_action ->
          transition_change =
            Transformer.build_entity!(Ash.Resource.Dsl, [:actions, :update], :change,
              change: AshStateMachine.BuiltinChanges.transition_state(step.on_success)
            )

          timestamp_change =
            Transformer.build_entity!(Ash.Resource.Dsl, [:actions, :update], :change,
              change:
                Ash.Resource.Change.Builtins.set_attribute(:state_entered_at, &DateTime.utc_now/0)
            )

          updated_action = %{
            existing_action
            | changes: existing_action.changes ++ [transition_change, timestamp_change]
          }

          dsl
          |> Transformer.remove_entity([:actions], &(&1.name == step.action))
          |> Transformer.add_entity([:actions], updated_action)
      end
    end)
  end

  defp add_timeout_actions(dsl, steps) do
    steps
    |> Enum.flat_map(fn step ->
      step.timeouts
      |> Enum.filter(& &1.transition_to)
      |> Enum.map(fn timeout -> {step, timeout} end)
    end)
    |> Enum.reduce(dsl, fn {_step, timeout}, dsl ->
      action_name = :"__timeout_#{timeout.name}"

      action =
        Transformer.build_entity!(Ash.Resource.Dsl, [:actions], :update,
          name: action_name,
          changes: [
            Transformer.build_entity!(Ash.Resource.Dsl, [:actions, :update], :change,
              change: AshStateMachine.BuiltinChanges.transition_state(timeout.transition_to)
            ),
            Transformer.build_entity!(Ash.Resource.Dsl, [:actions, :update], :change,
              change:
                Ash.Resource.Change.Builtins.set_attribute(:state_entered_at, &DateTime.utc_now/0)
            )
          ]
        )

      Transformer.add_entity(dsl, [:actions], action)
    end)
  end

  def before?(AshStateMachine.Transformers.FillInTransitionDefaults), do: true
  def before?(AshStateMachine.Transformers.AddState), do: true
  def before?(AshStateMachine.Transformers.EnsureStateSelected), do: true
  def before?(AshOban.Transformers.SetDefaults), do: true
  def before?(AshOban.Transformers.DefineSchedulers), do: true
  def before?(AshOban.Transformers.DefineActionWorkers), do: true
  def before?(_), do: false
end
