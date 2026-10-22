defmodule AshWorkflow.Verifiers.ValidateResourceChangesAtomic do
  @moduledoc """
  Rejects a resource-level `change` that cannot run atomically when a workflow
  action it reaches is built atomic.

  A change in the resource's `changes` block applies to every update action,
  including the ones AshWorkflow generates. The generated timeout actions are
  built atomic, and the author has no declaration to set `require_atomic? false`
  on, so a non-atomic change makes every firing fail with
  `Ash.Error.Framework.MustBeAtomic`.
  """
  use Spark.Dsl.Verifier

  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Transformers.AddActions
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    with [_ | _] = actions <- atomic_workflow_actions(dsl),
         [_ | _] = changes <- non_atomic_update_changes(dsl) do
      {:error,
       DslError.exception(
         module: Verifier.get_persisted(dsl, :module),
         path: [:changes],
         message: message(changes, actions)
       )}
    else
      _ -> :ok
    end
  end

  # Every action AshWorkflow creates, plus transition actions it extends. A
  # transition action the author declared still counts: it fails the same way,
  # and `require_atomic? false` on it is the author's opt-out, which the filter
  # on `require_atomic?` respects. Automatic step actions and the actions a
  # timeout or `every` names are the author's own and stay out of this check.
  defp atomic_workflow_actions(dsl) do
    names = workflow_action_names(dsl)

    dsl
    |> Verifier.get_entities([:actions])
    |> Enum.filter(&(&1.name in names and &1.type == :update and &1.require_atomic?))
    |> Enum.map(& &1.name)
  end

  defp workflow_action_names(dsl) do
    steps =
      dsl
      |> Verifier.get_entities([:workflow])
      |> Enum.filter(&match?(%Step{}, &1))

    transitions = Enum.flat_map(steps, fn step -> Enum.map(step.transitions, & &1.name) end)

    timeouts =
      Enum.flat_map(steps, fn step ->
        step.timeouts
        |> Enum.filter(& &1.transition_to)
        |> Enum.map(&AddActions.timeout_action_name(step, &1))
      end)

    on_errors =
      steps
      |> Enum.filter(&(&1.on_error && &1.action))
      |> Enum.map(&AddActions.on_error_action_name/1)

    [AddActions.undo_action_name() | transitions ++ timeouts ++ on_errors]
  end

  defp non_atomic_update_changes(dsl) do
    dsl
    |> Verifier.get_entities([:changes])
    |> Enum.filter(&(:update in &1.on))
    |> Enum.map(fn %{change: {module, _opts}} -> module end)
    |> Enum.uniq()
    |> Enum.reject(&atomic?/1)
  end

  defp atomic?(module) do
    Code.ensure_compiled!(module)
    function_exported?(module, :atomic?, 0) and module.atomic?()
  end

  defp message(modules, actions) do
    """
    The resource-level changes #{Enum.map_join(modules, ", ", &inspect/1)} do not \
    implement `atomic/3`, so they cannot run on these workflow actions, which are \
    built atomic:

    #{Enum.map_join(actions, "\n", &"    :#{&1}")}

    A change in the resource's `changes` block applies to every update action, \
    including the ones AshWorkflow generates. Each of those actions would fail \
    with Ash.Error.Framework.MustBeAtomic, and a timeout would retry on every \
    sweep without leaving its step.

    Either implement `atomic/3` on the change, or restrict it to the actions \
    that need it, with `on: [:create]` or by moving it into those actions' own \
    `change` declarations.
    """
  end
end
