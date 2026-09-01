defmodule AshWorkflow.Verifiers.ValidateUndo do
  @moduledoc """
  Verifies that undo is coherently configured.

  Checks, in order:

  - `undo` requires a `transition_log`. Undo reverses a logged row; without a
    log there is nothing to reverse and no target to rewind to.
  - The log resource must declare a self-referencing `belongs_to :undoes`, the
    pointer from an undo row to the row it reverses. Regenerate the log with
    `mix ash_workflow.gen.transition_log` if it predates undo.
  - `undo` requires at least one transition marked `undoable?: true`, so an
    `undo` block that can never fire is a compile error rather than an action
    that always refuses.
  - `undoable?: true` requires an `undo` block, for the same reason in reverse.
  - `same_actor?` requires `belongs_to_actor` on the log. Without a recorded
    actor there is nothing to compare the caller against, and every undo would
    refuse with `:no_actor`.

  A no-op when the workflow declares neither `undo` nor any undoable
  transition.
  """
  use Spark.Dsl.Verifier

  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Info
  alias AshWorkflow.TransitionLog
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    case {Info.undo(dsl), undoable_transitions(dsl)} do
      {nil, []} -> :ok
      {nil, [{step, transition} | _]} -> {:error, orphan_transition_error(step, transition)}
      {undo, undoable} -> validate_undo(dsl, undo, undoable)
    end
  end

  defp validate_undo(dsl, undo, undoable) do
    with :ok <- validate_has_log(dsl),
         :ok <- validate_undoes_relationship(dsl),
         :ok <- validate_has_undoable(undoable) do
      validate_same_actor(dsl, undo)
    end
  end

  defp undoable_transitions(dsl) do
    dsl
    |> Info.steps()
    |> Enum.filter(&Step.manual?/1)
    |> Enum.flat_map(fn step ->
      step.transitions
      |> Enum.filter(& &1.undoable?)
      |> Enum.map(&{step, &1})
    end)
  end

  defp validate_has_log(dsl) do
    if Info.transition_log(dsl) do
      :ok
    else
      {:error,
       undo_error("""
       `undo` requires a `transition_log`.

       Undo rewinds to the state recorded on the previous log row, and records the \
       rewind as a new row pointing back at the one it reverses. Neither is possible \
       without a log.

       Scaffold one with `mix ash_workflow.gen.transition_log` and declare it \
       alongside the `undo` block.
       """)}
    end
  end

  defp validate_undoes_relationship(dsl) do
    log = Info.transition_log(dsl)

    if TransitionLog.undoes_foreign_key(log.resource) do
      :ok
    else
      {:error,
       undo_error("""
       transition_log #{inspect(log.resource)} has no self-referencing `undoes` relationship.

       An undo is recorded as a new row pointing at the row it reverses, rather than \
       by mutating that row — which is what keeps the log append-only and both \
       readings of history derivable. Add:

           belongs_to :undoes, __MODULE__, allow_nil?: true

       and accept `:undoes_id` in the log's create action.
       """)}
    end
  end

  defp validate_has_undoable(undoable) do
    if undoable == [] do
      {:error,
       undo_error("""
       This workflow declares `undo` but no transition is marked `undoable?: true`, \
       so the generated `undo` action would refuse every call.

       Mark the transitions that are safe to rewind:

           transition :approve, to: :done, undoable?: true
       """)}
    else
      :ok
    end
  end

  defp validate_same_actor(_dsl, %{same_actor?: false}), do: :ok

  defp validate_same_actor(dsl, %{same_actor?: true}) do
    log = Info.transition_log(dsl)

    case log.belongs_to_actor do
      [_actor | _] ->
        :ok

      [] ->
        {:error,
         undo_error("""
         `same_actor?` is set, but transition_log #{inspect(log.resource)} records no actor, \
         so there is nothing to compare the caller against and every undo would refuse.

         Configure actor capture on the log:

             transition_log #{inspect(log.resource)} do
               belongs_to_actor :user, MyApp.Accounts.User
             end
         """)}
    end
  end

  defp orphan_transition_error(step, transition) do
    DslError.exception(
      path: [:workflow, :step, step.name, :transition, transition.name],
      message: """
      Transition :#{transition.name} on step :#{step.name} is marked `undoable?: true`, \
      but this workflow has no `undo` block, so no `undo` action is generated and the \
      flag has no effect.

      Add one to the `workflow` section:

          undo do
            within {30, :minutes}
          end
      """
    )
  end

  defp undo_error(message) do
    DslError.exception(path: [:workflow, :undo], message: message)
  end
end
