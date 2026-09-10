defmodule AshWorkflow.Changes.ConditionalTransition do
  @moduledoc """
  An Ash change that evaluates conditional routes at runtime to determine the
  transition target.

  Routes are evaluated in order. The first route whose `when` expression matches
  wins. If no route matches, the changeset gets an error.

  Conditions are evaluated against the record with the action's changes folded
  in, so a route can branch on a value the same call accepted:

      transition :decide do
        accept [:decision]
        route :approved, when: expr(decision == :approve)
        route :rejected, when: expr(decision == :reject)
      end

  This change is appended after the action's own changes, so by the time it
  runs the accepted input and any change the action declared are both on the
  changeset. Values not touched by the action come from the record as it was
  loaded.

  Used internally by the AddActions transformer for transitions with conditional
  routes. Not intended for direct use.
  """
  use Ash.Resource.Change

  alias AshWorkflow.Telemetry

  @impl true
  def change(changeset, opts, _context) do
    routes = opts[:routes]
    transition_name = opts[:transition_name]
    resource = changeset.resource

    Ash.Changeset.before_action(changeset, fn changeset ->
      result = find_matching_target(routes, record_with_changes(changeset), resource)

      emit_route_evaluation(result, changeset, routes, transition_name)

      case result do
        {:ok, target} ->
          AshStateMachine.transition_state(changeset, target)

        {:error, route, error} ->
          Ash.Changeset.add_error(
            changeset,
            "Route condition evaluation failed for transition :#{transition_name} " <>
              "(route to :#{route.to}): #{inspect(error)}"
          )

        nil ->
          Ash.Changeset.add_error(
            changeset,
            "No matching condition for transition :#{transition_name}. " <>
              "Record did not match any of the #{length(routes)} configured routes."
          )
      end
    end)
  end

  # Emitted whether or not a route matched, since a transition that matched
  # nothing is the case worth seeing on a dashboard: it fails the action.
  defp emit_route_evaluation(result, changeset, routes, transition_name) do
    state_attribute = AshStateMachine.Info.state_machine_state_attribute!(changeset.resource)

    Telemetry.route_evaluation(%{
      resource: changeset.resource,
      transition_name: transition_name,
      from_state: Map.get(changeset.data, state_attribute),
      matched_route: matched_route(result),
      routes_evaluated: length(routes)
    })
  end

  defp matched_route({:ok, target}), do: target
  defp matched_route(_no_match), do: nil

  # Folds the changeset's pending attribute changes into its data, so a route
  # condition sees the input the transition accepted rather than the record as
  # it was before the call. `AshWorkflow.Changes.ConditionalOnSuccess` reads
  # the record the same way.
  defp record_with_changes(changeset) do
    case Ash.Changeset.apply_attributes(changeset, force?: true) do
      {:ok, record} -> record
      {:error, _changeset} -> changeset.data
    end
  end

  defp find_matching_target(routes, record, resource) do
    Enum.reduce_while(routes, nil, fn route, _acc ->
      case Ash.Expr.eval(route.when, record: record, resource: resource) do
        {:ok, true} ->
          {:halt, {:ok, route.to}}

        {:ok, _} ->
          {:cont, nil}

        {:error, error} ->
          {:halt, {:error, route, error}}
      end
    end)
  end
end
