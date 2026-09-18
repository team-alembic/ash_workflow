defmodule AshWorkflow.Changes.ConditionalOnSuccess do
  @moduledoc """
  An Ash change that evaluates an automatic step's `on_success` routes to
  determine the transition target.

  Like `AshWorkflow.Changes.ConditionalTransition`, this evaluates routes
  against the record with the action's changes folded in — including any
  attributes the action computed — since the whole point of routing on
  `on_success` is to branch on what the action produced.

  In practice this means evaluating against the changeset with its changes
  applied (but not yet persisted): this change is appended after the action's
  own changes, so by the time it runs, the action's business logic has
  already been folded into the changeset. Routes are evaluated in order. The
  first route whose `when` expression matches wins; a route with no `when`
  (an unconditional fallback) always matches.

  If no route matches, that is a distinct failure rather than a silent no-op:
  `AshWorkflow.Errors.NoMatchingRoute` is added to the changeset, which fails
  the action and sends it down the step's own error path the same way any
  other action failure does. `AshWorkflow.Verifiers.ValidateWorkflow` requires
  a step whose `on_success` is not statically exhaustive to declare either
  `on_error` or a timeout with `transition_to`, so a step that compiles always
  has somewhere for such a record to end up.

  Used internally by the AddActions transformer for automatic steps whose
  `on_success` needs runtime evaluation (more than one entry, or a `when` on
  its single entry). Not intended for direct use.
  """
  use Ash.Resource.Change

  alias AshWorkflow.Errors.NoMatchingRoute

  @impl true
  def change(changeset, opts, _context) do
    routes = opts[:routes]
    step_name = opts[:step_name]
    action_name = opts[:action]
    resource = changeset.resource

    Ash.Changeset.before_action(changeset, fn changeset ->
      record = record_after_action(changeset)

      case find_matching_target(routes, record, resource) do
        {:ok, target} ->
          AshStateMachine.transition_state(changeset, target)

        {:error, route, error} ->
          Ash.Changeset.add_error(
            changeset,
            "Route condition evaluation failed for on_success of step :#{step_name} " <>
              "(route to :#{route.to}): #{inspect(error)}"
          )

        nil ->
          Ash.Changeset.add_error(
            changeset,
            NoMatchingRoute.exception(
              resource: resource,
              step: step_name,
              action: action_name
            )
          )
      end
    end)
  end

  # Folds the changeset's pending attribute changes into its data, so route
  # conditions see what the step's action computed — screen_score set by a
  # prior change, say — rather than the record as it was on entry to the step.
  defp record_after_action(changeset) do
    case Ash.Changeset.apply_attributes(changeset, force?: true) do
      {:ok, record} -> record
      {:error, _changeset} -> changeset.data
    end
  end

  defp find_matching_target(routes, record, resource) do
    Enum.reduce_while(routes, nil, fn route, _acc ->
      case eval_route(route, record, resource) do
        {:ok, true} ->
          {:halt, {:ok, route.to}}

        {:ok, _} ->
          {:cont, nil}

        {:error, error} ->
          {:halt, {:error, route, error}}
      end
    end)
  end

  # A route with no `when` is an unconditional fallback and always matches.
  defp eval_route(%{when: nil}, _record, _resource), do: {:ok, true}

  defp eval_route(route, record, resource),
    do: Ash.Expr.eval(route.when, record: record, resource: resource)
end
