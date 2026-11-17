defmodule AshWorkflow.Verifiers.ValidateWorkflow do
  @moduledoc "Verifies that workflow step declarations are valid and internally consistent."

  use Spark.Dsl.Verifier

  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Entities.Transition
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    steps =
      dsl
      |> Verifier.get_entities([:workflow])
      |> Enum.filter(&match?(%Step{}, &1))

    with :ok <- validate_has_steps(steps),
         :ok <- validate_initial_steps(steps),
         :ok <- validate_step_configs(steps),
         :ok <- validate_references(steps),
         :ok <- validate_timeout_actions(dsl, steps),
         :ok <- validate_every_actions(dsl, steps),
         :ok <- validate_shared_transition_policies(steps),
         :ok <- validate_create_starting_steps(dsl, steps) do
      validate_reachability(steps)
    end
  end

  defp validate_has_steps([]) do
    {:error,
     DslError.exception(
       path: [:workflow],
       message: "Workflow must have at least one non-terminal step."
     )}
  end

  defp validate_has_steps(steps) do
    if Enum.all?(steps, &Step.terminal?/1) do
      {:error,
       DslError.exception(
         path: [:workflow],
         message: "Workflow must have at least one non-terminal step."
       )}
    else
      :ok
    end
  end

  defp validate_initial_steps(steps) do
    case Enum.find(steps, &(&1.initial and Step.terminal?(&1))) do
      nil ->
        :ok

      step ->
        {:error,
         DslError.exception(
           path: [:workflow, :step, step.name],
           message: "Terminal step :#{step.name} cannot have initial: true."
         )}
    end
  end

  # A create picks its starting step with `transition_state`, so a literal
  # target is checked here rather than when the first record is created.
  defp validate_create_starting_steps(dsl, steps) do
    initial_names = steps |> Step.find_initials() |> Enum.map(& &1.name)
    starts = create_starting_steps(dsl)

    with :ok <- validate_start_targets(starts, initial_names) do
      validate_initial_steps_started(starts, initial_names)
    end
  end

  defp validate_start_targets(starts, initial_names) do
    case Enum.find(starts, &invalid_start?(&1, initial_names)) do
      nil ->
        :ok

      %{action: action, upsert?: true, target: target} ->
        {:error,
         DslError.exception(
           path: [:actions, :create, action],
           message:
             "Create action :#{action} upserts and calls transition_state(#{inspect(target)}). ash_state_machine only lets an upsert move to a state that a transition declares for that action, and a workflow declares none for creates. An upserting create starts records in the first initial step. Remove `upsert? true` or the transition_state change."
         )}

      %{action: action, target: target} ->
        {:error,
         DslError.exception(
           path: [:actions, :create, action],
           message:
             "Create action :#{action} starts records in #{inspect(target)}, which is not an initial step. Mark step #{inspect(target)} with `initial true`, or start in one of #{inspect(initial_names)}."
         )}
    end
  end

  defp invalid_start?(%{target: target}, _initial_names) when not is_atom(target), do: false
  defp invalid_start?(%{upsert?: true}, _initial_names), do: true
  defp invalid_start?(%{target: target}, initial_names), do: target not in initial_names

  # Every initial step after the first needs a create that starts records in
  # it. One that no create names is most often a copied `initial true`.
  defp validate_initial_steps_started(starts, [_default | other_initial_names]) do
    if Enum.any?(starts, &(not is_atom(&1.target))) do
      :ok
    else
      targets = MapSet.new(starts, & &1.target)

      case Enum.reject(other_initial_names, &MapSet.member?(targets, &1)) do
        [] ->
          :ok

        [name | _] ->
          {:error,
           DslError.exception(
             path: [:workflow, :step, name],
             message:
               "Step #{inspect(name)} is marked `initial true`, but no create action starts a record in it. Only the first initial step is the default for a create. Add `change transition_state(#{inspect(name)})` to a create action, or remove `initial true`."
           )}
      end
    end
  end

  defp validate_initial_steps_started(_starts, []), do: :ok

  defp create_starting_steps(dsl) do
    global_changes =
      dsl
      |> Verifier.get_entities([:changes])
      |> Enum.filter(&(:create in List.wrap(Map.get(&1, :on))))

    dsl
    |> Verifier.get_entities([:actions])
    |> Enum.filter(&match?(%Ash.Resource.Actions.Create{}, &1))
    |> Enum.flat_map(fn action ->
      (Map.get(action, :changes, []) ++ global_changes)
      |> Enum.flat_map(&transition_state_target/1)
      |> Enum.map(&%{action: action.name, upsert?: action.upsert?, target: &1})
    end)
  end

  defp transition_state_target(%Ash.Resource.Change{
         change: {AshStateMachine.BuiltinChanges.TransitionState, opts}
       }),
       do: [Keyword.get(opts, :target)]

  defp transition_state_target(_change), do: []

  defp validate_step_configs(steps) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case validate_step(step) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_step(%{terminal: true} = step) do
    cond do
      step.action != nil ->
        step_error(step, "Terminal step :#{step.name} must not have an action.")

      step.on_success != [] ->
        step_error(step, "Terminal step :#{step.name} must not have on_success.")

      step.on_error != nil ->
        step_error(step, "Terminal step :#{step.name} must not have on_error.")

      step.transitions != [] ->
        step_error(step, "Terminal step :#{step.name} must not have transitions.")

      step.timeouts != [] ->
        step_error(step, "Terminal step :#{step.name} must not have timeouts.")

      step.everys != [] ->
        step_error(step, "Terminal step :#{step.name} must not have every.")

      true ->
        :ok
    end
  end

  defp validate_step(step) do
    cond do
      Step.terminal?(step) -> :ok
      Step.wait_state?(step) -> validate_wait_state(step)
      step.transitions == [] -> validate_automatic_step(step)
      true -> validate_manual_step(step)
    end
  end

  defp validate_wait_state(step) do
    cond do
      step.on_success != [] ->
        step_error(
          step,
          "Step :#{step.name} has no action, so on_success would never fire. A timeout's or on_signal's transition_to is what moves a wait state along."
        )

      step.on_error != nil ->
        step_error(
          step,
          "Step :#{step.name} has no action, so on_error would never fire."
        )

      not (Enum.any?(step.timeouts, & &1.transition_to) or
               Enum.any?(step.on_signals, & &1.transition_to)) ->
        step_error(
          step,
          "Step :#{step.name} has no action and no transitions, so a timeout or on_signal is its only way out, but none of its timeouts or on_signals declare transition_to. Records entering it would never leave."
        )

      true ->
        validate_timeouts(step)
    end
  end

  defp validate_manual_step(step) do
    cond do
      step.action != nil ->
        step_error(
          step,
          "Step :#{step.name} has transitions and therefore cannot also define an action. User actions are defined via transitions."
        )

      step.on_success != [] ->
        step_error(
          step,
          "Step :#{step.name} has transitions and therefore cannot also define on_success. Use transitions instead."
        )

      step.on_error != nil ->
        step_error(
          step,
          "Step :#{step.name} has transitions and therefore cannot also define on_error. Use transitions instead."
        )

      true ->
        validate_timeouts(step)
    end
  end

  defp validate_automatic_step(step) do
    cond do
      step.action == nil ->
        step_error(
          step,
          "Step :#{step.name} must either declare an action (automatic step) or at least one transition (manual step)."
        )

      step.on_success == [] ->
        step_error(
          step,
          "Automatic step :#{step.name} must have on_success."
        )

      true ->
        with :ok <- validate_on_success_ordering(step),
             :ok <- validate_on_success_exhaustive(step) do
          validate_timeouts(step)
        end
    end
  end

  # An `on_success` entry with no `when` is unconditional and always matches,
  # so at most one is allowed per step, and if conditional entries are also
  # present the unconditional one must come last — it is the fallback that
  # runs only when nothing more specific matched. An unconditional entry
  # declared earlier would shadow every entry after it, since it always
  # matches first.
  defp validate_on_success_ordering(%{on_success: routes} = step) do
    unconditional_indexes =
      routes
      |> Enum.with_index()
      |> Enum.filter(fn {route, _index} -> is_nil(route.when) end)
      |> Enum.map(fn {_route, index} -> index end)

    cond do
      length(unconditional_indexes) > 1 ->
        step_error(
          step,
          "Step :#{step.name} has more than one unconditional on_success (no `when`). " <>
            "Only one is allowed, as the trailing fallback after any conditional ones."
        )

      unconditional_indexes != [] and List.first(unconditional_indexes) != length(routes) - 1 ->
        step_error(
          step,
          "Step :#{step.name} has an unconditional on_success before conditional ones. " <>
            "An unconditional on_success always matches, so it would shadow every " <>
            "on_success declared after it. Move it last, as the fallback, or add a " <>
            "`when` condition to it."
        )

      true ->
        :ok
    end
  end

  # A step whose on_success entries are all conditional, with none acting as an
  # unconditional fallback, can run its action and have nothing match. That
  # fails the action and leaves the record in the step, so the step needs some
  # other declared way out: on_error, which the scheduler runs once the final
  # attempt has failed, or a timeout with transition_to, which moves the record
  # on once its deadline passes. With neither, the record stays in the step and
  # the action is retried on every scheduler cycle forever — a dead end this
  # verifier can see coming from the declaration alone.
  defp validate_on_success_exhaustive(step) do
    if Step.on_success_exhaustive?(step) or not is_nil(step.on_error) or timeout_escape?(step) do
      :ok
    else
      step_error(
        step,
        "Step :#{step.name} has no unconditional on_success (a trailing entry with no " <>
          "`when`), no on_error, and no timeout with transition_to. If the action " <>
          "succeeds and none of its on_success conditions match, the record stays in " <>
          "this step and the action is retried on every cycle. Add a trailing " <>
          "unconditional on_success as the fallback, declare on_error, or give the step " <>
          "a timeout with transition_to."
      )
    end
  end

  defp timeout_escape?(step), do: Enum.any?(step.timeouts, & &1.transition_to)

  defp validate_timeouts(step) do
    Enum.reduce_while(step.timeouts, :ok, fn timeout, :ok ->
      with :ok <- validate_timeout_deadline(step, timeout),
           :ok <- validate_timeout_target(step, timeout) do
        {:cont, :ok}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_timeout_deadline(step, timeout) do
    cond do
      timeout.fire_after != nil and timeout.fire_at != nil ->
        step_error(
          step,
          "Timeout :#{timeout.name} on step :#{step.name} must have either fire_after or fire_at, not both. " <>
            "fire_after measures an offset from `field`; fire_at names a field that already holds the deadline instant."
        )

      timeout.fire_after == nil and timeout.fire_at == nil ->
        step_error(
          step,
          "Timeout :#{timeout.name} on step :#{step.name} must have either fire_after or fire_at."
        )

      timeout.fire_at != nil and timeout.field != nil ->
        step_error(
          step,
          "Timeout :#{timeout.name} on step :#{step.name} has both fire_at and field. " <>
            "field is the anchor fire_after measures from, and fire_at names the deadline itself, so it has no anchor to measure from."
        )

      true ->
        :ok
    end
  end

  defp validate_timeout_target(step, timeout) do
    cond do
      timeout.action != nil and timeout.transition_to != nil ->
        step_error(
          step,
          "Timeout :#{timeout.name} on step :#{step.name} must have either action or transition_to, not both."
        )

      timeout.action == nil and timeout.transition_to == nil ->
        step_error(
          step,
          "Timeout :#{timeout.name} on step :#{step.name} must have either action or transition_to."
        )

      true ->
        :ok
    end
  end

  # A timeout's `action` is handed to the scheduler as the action to invoke, so
  # a name that matches nothing fails when the deadline passes rather than at
  # compile time. `AshWorkflow.Transformers.AddActions` already raises when it
  # rewrites the action to add `AshWorkflow.Changes.RecordEvent`, for both a
  # timeout and an `every`; a timeout naming no action at all was passed
  # through unchecked.
  defp validate_timeout_actions(dsl, steps) do
    action_names =
      dsl
      |> Verifier.get_entities([:actions])
      |> MapSet.new(& &1.name)

    steps
    |> Enum.flat_map(fn step -> Enum.map(step.timeouts, &{step, &1}) end)
    |> Enum.reject(fn {_step, timeout} -> is_nil(timeout.action) end)
    |> Enum.reduce_while(:ok, fn {step, timeout}, :ok ->
      if MapSet.member?(action_names, timeout.action) do
        {:cont, :ok}
      else
        {:halt,
         step_error(
           step,
           "Timeout :#{timeout.name} on step :#{step.name} references action :#{timeout.action}, but no such action is defined on the resource."
         )}
      end
    end)
  end

  # An `every`'s `action` is required, so unlike a timeout's `action` this can
  # never be nil, but the same reasoning applies: it is handed to the scheduler
  # as the action to invoke, so a name that matches nothing would otherwise
  # fail only when the interval elapses rather than at compile time.
  defp validate_every_actions(dsl, steps) do
    action_names =
      dsl
      |> Verifier.get_entities([:actions])
      |> MapSet.new(& &1.name)

    steps
    |> Enum.flat_map(fn step -> Enum.map(step.everys, &{step, &1}) end)
    |> Enum.reduce_while(:ok, fn {step, every}, :ok ->
      if MapSet.member?(action_names, every.action) do
        {:cont, :ok}
      else
        {:halt,
         step_error(
           step,
           "every :#{every.name} on step :#{step.name} references action :#{every.action}, but no such action is defined on the resource."
         )}
      end
    end)
  end

  defp validate_references(steps) do
    step_names = MapSet.new(steps, & &1.name)

    Enum.reduce_while(steps, :ok, fn step, :ok ->
      with :ok <- validate_on_success_refs(step_names, step),
           :ok <- validate_ref(step_names, step.on_error, step, "on_error"),
           :ok <- validate_transition_refs(step_names, step),
           :ok <- validate_timeout_refs(step_names, step) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp validate_on_success_refs(step_names, step) do
    targets = Step.on_success_targets(step)

    Enum.reduce_while(targets, :ok, fn target, :ok ->
      if MapSet.member?(step_names, target) do
        {:cont, :ok}
      else
        {:halt,
         step_error(step, "Step :#{step.name} on_success references unknown step :#{target}.")}
      end
    end)
  end

  defp validate_ref(_step_names, nil, _step, _field), do: :ok

  defp validate_ref(step_names, target, step, field) do
    if MapSet.member?(step_names, target) do
      :ok
    else
      step_error(step, "Step :#{step.name} #{field} references unknown step :#{target}.")
    end
  end

  defp validate_transition_refs(step_names, step) do
    Enum.reduce_while(step.transitions, :ok, fn transition, :ok ->
      with :ok <- validate_transition_has_target(step, transition),
           :ok <- validate_transition_target_refs(step_names, step, transition) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp validate_transition_has_target(step, transition) do
    cond do
      transition.to != nil and transition.routes != [] ->
        step_error(
          step,
          "Transition :#{transition.name} on step :#{step.name} has both `to` and conditional routes. Use one or the other."
        )

      transition.to == nil and transition.routes == [] ->
        step_error(
          step,
          "Transition :#{transition.name} on step :#{step.name} must have either `to` or conditional routes."
        )

      true ->
        :ok
    end
  end

  defp validate_transition_target_refs(step_names, step, transition) do
    targets = Transition.all_targets(transition)

    Enum.reduce_while(targets, :ok, fn target, :ok ->
      if MapSet.member?(step_names, target) do
        {:cont, :ok}
      else
        {:halt,
         step_error(
           step,
           "Transition :#{transition.name} on step :#{step.name} references unknown step :#{target}."
         )}
      end
    end)
  end

  defp validate_timeout_refs(step_names, step) do
    Enum.reduce_while(step.timeouts, :ok, fn timeout, :ok ->
      case timeout.transition_to do
        nil ->
          {:cont, :ok}

        target ->
          validate_timeout_target(step_names, step, timeout, target)
      end
    end)
  end

  defp validate_timeout_target(step_names, step, timeout, target) do
    if MapSet.member?(step_names, target) do
      {:cont, :ok}
    else
      {:halt,
       step_error(
         step,
         "Timeout :#{timeout.name} on step :#{step.name} transition_to references unknown step :#{target}."
       )}
    end
  end

  # A transition name declared on several steps merges into one Ash action, and
  # a step's `policy` is applied to that action. So if two steps share a
  # transition name but declare different policies, both policies end up on the
  # same action — and because Ash requires every applicable policy to pass, each
  # actor is blocked by the other step's policy and nobody can use the action.
  #
  # That is a silent lockout at runtime, so reject it at compile time instead.
  defp validate_shared_transition_policies(steps) do
    steps
    |> Enum.filter(&Step.manual?/1)
    |> Enum.flat_map(fn step -> Enum.map(step.transitions, &{&1.name, step}) end)
    |> Enum.group_by(fn {name, _step} -> name end, fn {_name, step} -> step end)
    |> Enum.filter(fn {_name, steps} -> length(steps) > 1 end)
    |> Enum.find_value(:ok, fn {name, sharing_steps} ->
      policies = sharing_steps |> Enum.map(& &1.policy) |> Enum.uniq()

      if length(policies) > 1 do
        shared_by = Enum.map_join(sharing_steps, ", ", &":#{&1.name}")

        {:error,
         DslError.exception(
           path: [:workflow],
           message: """
           Transition :#{name} is declared on steps with different policies (#{shared_by}).

           Steps that share a transition name merge into a single Ash action, and \
           each step's `policy` is applied to that action. Ash requires every \
           applicable policy to pass, so the differing policies would block each \
           other and nobody could call :#{name}.

           Either give the transitions distinct names per step, declare the same \
           policy on each step, or drop the step-level `policy` and authorize \
           :#{name} with a resource-level policy that can inspect the state.
           """
         )}
      end
    end)
  end

  defp validate_reachability(steps) do
    case Step.find_initials(steps) do
      [] -> :ok
      initial_steps -> do_validate_reachability(initial_steps, steps)
    end
  end

  defp do_validate_reachability(initial_steps, steps) do
    step_map = Map.new(steps, &{&1.name, &1})
    initial_names = Enum.map(initial_steps, & &1.name)
    reachable = MapSet.new(bfs(initial_names, step_map, []))
    all_names = MapSet.new(steps, & &1.name)
    unreachable = MapSet.difference(all_names, reachable)

    if MapSet.size(unreachable) == 0 do
      :ok
    else
      unreachable_list = unreachable |> MapSet.to_list() |> Enum.sort()

      {:error,
       DslError.exception(
         path: [:workflow],
         message:
           "The following steps are not reachable from #{describe_initial(initial_names)}: #{inspect(unreachable_list)}" <>
             entry_hint(unreachable_list, steps)
       )}
    end
  end

  defp describe_initial([name]), do: "the initial step #{inspect(name)}"
  defp describe_initial(names), do: "any initial step #{inspect(names)}"

  # `visited` is a plain list rather than a MapSet: workflows have a handful of
  # steps, so the linear membership check costs nothing at compile time.
  @spec bfs([atom()], %{optional(atom()) => Step.t()}, [atom()]) :: [atom()]
  defp bfs([], _step_map, visited), do: visited

  defp bfs([name | rest], step_map, visited) do
    if name in visited do
      bfs(rest, step_map, visited)
    else
      visited = [name | visited]

      neighbors =
        case Map.get(step_map, name) do
          nil -> []
          step -> successors(step)
        end

      bfs(rest ++ neighbors, step_map, visited)
    end
  end

  defp successors(step) do
    Step.on_success_targets(step) ++
      Enum.reject([step.on_error], &is_nil/1) ++
      Enum.flat_map(step.transitions, &Transition.all_targets/1) ++
      (step.timeouts |> Enum.map(& &1.transition_to) |> Enum.reject(&is_nil/1)) ++
      (step.on_signals |> Enum.map(& &1.transition_to) |> Enum.reject(&is_nil/1))
  end

  # A step nothing leads into can only be a starting step, so the likely fix is
  # `initial true` rather than a missing transition.
  defp entry_hint(unreachable_names, steps) do
    entered = MapSet.new(Enum.flat_map(steps, &successors/1))

    case Enum.reject(unreachable_names, &MapSet.member?(entered, &1)) do
      [] ->
        ""

      [name] ->
        ". No step leads into #{inspect(name)}. Mark it `initial true` if records start there."

      names ->
        ". No step leads into #{inspect(names)}. Mark each one that records start in with `initial true`."
    end
  end

  defp step_error(step, message) do
    {:error,
     DslError.exception(
       path: [:workflow, :step, step.name],
       message: message
     )}
  end
end
