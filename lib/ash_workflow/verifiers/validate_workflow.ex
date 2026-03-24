defmodule AshWorkflow.Verifiers.ValidateWorkflow do
  @moduledoc "Verifies that workflow step declarations are valid and internally consistent."

  use Spark.Dsl.Verifier

  alias AshWorkflow.Entities.Transition
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    steps = Verifier.get_entities(dsl, [:workflow])

    with :ok <- validate_has_steps(steps),
         :ok <- validate_step_configs(steps),
         :ok <- validate_references(steps) do
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
    if Enum.all?(steps, & &1.terminal) do
      {:error,
       DslError.exception(
         path: [:workflow],
         message: "Workflow must have at least one non-terminal step."
       )}
    else
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

      step.on_success != nil ->
        step_error(step, "Terminal step :#{step.name} must not have on_success.")

      step.on_error != nil ->
        step_error(step, "Terminal step :#{step.name} must not have on_error.")

      step.transitions != [] ->
        step_error(step, "Terminal step :#{step.name} must not have transitions.")

      step.timeouts != [] ->
        step_error(step, "Terminal step :#{step.name} must not have timeouts.")

      true ->
        :ok
    end
  end

  defp validate_step(%{manual: true} = step) do
    cond do
      step.transitions == [] ->
        step_error(step, "Manual step :#{step.name} must have at least one transition.")

      step.action != nil ->
        step_error(
          step,
          "Manual step :#{step.name} must not have an action. User actions are defined via transitions."
        )

      step.on_success != nil ->
        step_error(
          step,
          "Manual step :#{step.name} must not have on_success. Use transitions instead."
        )

      step.on_error != nil ->
        step_error(
          step,
          "Manual step :#{step.name} must not have on_error. Use transitions instead."
        )

      true ->
        validate_timeouts(step)
    end
  end

  defp validate_step(step) do
    cond do
      step.action == nil ->
        step_error(step, "Automatic step :#{step.name} must have an action.")

      step.on_success == nil ->
        step_error(step, "Automatic step :#{step.name} must have on_success.")

      step.transitions != [] ->
        step_error(
          step,
          "Automatic step :#{step.name} must not have transitions. Use on_success/on_error instead."
        )

      true ->
        validate_timeouts(step)
    end
  end

  defp validate_timeouts(step) do
    Enum.reduce_while(step.timeouts, :ok, fn timeout, :ok ->
      cond do
        timeout.action != nil and timeout.transition_to != nil ->
          {:halt,
           step_error(
             step,
             "Timeout :#{timeout.name} on step :#{step.name} must have either action or transition_to, not both."
           )}

        timeout.action == nil and timeout.transition_to == nil ->
          {:halt,
           step_error(
             step,
             "Timeout :#{timeout.name} on step :#{step.name} must have either action or transition_to."
           )}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_references(steps) do
    step_names = MapSet.new(steps, & &1.name)

    Enum.reduce_while(steps, :ok, fn step, :ok ->
      with :ok <- validate_ref(step_names, step.on_success, step, "on_success"),
           :ok <- validate_ref(step_names, step.on_error, step, "on_error"),
           :ok <- validate_transition_refs(step_names, step),
           :ok <- validate_timeout_refs(step_names, step) do
        {:cont, :ok}
      else
        error -> {:halt, error}
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

  defp validate_reachability(steps) do
    non_terminal = Enum.reject(steps, & &1.terminal)

    case non_terminal do
      [] -> :ok
      [first | _] -> do_validate_reachability(first, steps)
    end
  end

  defp do_validate_reachability(first_step, steps) do
    step_map = Map.new(steps, &{&1.name, &1})
    reachable = bfs([first_step.name], step_map, MapSet.new())
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

  defp bfs([], _step_map, visited), do: visited

  defp bfs([name | rest], step_map, visited) do
    if MapSet.member?(visited, name) do
      bfs(rest, step_map, visited)
    else
      visited = MapSet.put(visited, name)

      neighbors =
        case Map.get(step_map, name) do
          nil ->
            []

          step ->
            successors =
              [step.on_success, step.on_error]
              |> Enum.reject(&is_nil/1)

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
