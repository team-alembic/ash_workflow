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
         :ok <- validate_single_initial(steps),
         :ok <- validate_step_configs(steps),
         :ok <- validate_references(steps),
         :ok <- validate_timeout_actions(dsl, steps),
         :ok <- validate_every_actions(dsl, steps),
         :ok <- validate_shared_transition_policies(steps) do
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

  defp validate_single_initial(steps) do
    initial_steps = Enum.filter(steps, & &1.initial)

    case initial_steps do
      [_, _ | _] ->
        names = Enum.map(initial_steps, & &1.name)

        {:error,
         DslError.exception(
           path: [:workflow],
           message: "Only one step can have initial: true, but found: #{inspect(names)}"
         )}

      [step] ->
        if Step.terminal?(step) do
          {:error,
           DslError.exception(
             path: [:workflow, :step, step.name],
             message: "Terminal step :#{step.name} cannot have initial: true."
           )}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

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
          "Step :#{step.name} has no action, so on_success would never fire. A timeout's transition_to is what moves a wait state along."
        )

      step.on_error != nil ->
        step_error(
          step,
          "Step :#{step.name} has no action, so on_error would never fire."
        )

      not Enum.any?(step.timeouts, & &1.transition_to) ->
        step_error(
          step,
          "Step :#{step.name} has no action and no transitions, so a timeout is its only way out, but none of its timeouts declare transition_to. Records entering it would never leave."
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
    case Step.find_initial(steps) do
      nil -> :ok
      initial -> do_validate_reachability(initial, steps)
    end
  end

  defp do_validate_reachability(first_step, steps) do
    step_map = Map.new(steps, &{&1.name, &1})
    reachable = MapSet.new(bfs([first_step.name], step_map, []))
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
           "The following steps are not reachable from the first step :#{first_step.name}: #{inspect(unreachable_list)}"
       )}
    end
  end

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
          nil ->
            []

          step ->
            successors =
              Step.on_success_targets(step) ++ ([step.on_error] |> Enum.reject(&is_nil/1))

            transition_targets =
              Enum.flat_map(step.transitions, &Transition.all_targets/1)

            timeout_targets =
              step.timeouts |> Enum.map(& &1.transition_to) |> Enum.reject(&is_nil/1)

            successors ++ transition_targets ++ timeout_targets
        end

      bfs(rest ++ neighbors, step_map, visited)
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
