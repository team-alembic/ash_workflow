defmodule AshWorkflow.Changes.ConditionalTransition do
  @moduledoc """
  An Ash change that evaluates conditional routes at runtime to determine the
  transition target.

  Routes are evaluated in order. The first route whose `when` expression matches
  the current record wins. If no route matches, the changeset gets an error.

  Used internally by the AddActions transformer for transitions with conditional
  routes. Not intended for direct use.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    routes = opts[:routes]
    transition_name = opts[:transition_name]
    resource = changeset.resource

    Ash.Changeset.before_action(changeset, fn changeset ->
      target = find_matching_target(routes, changeset.data, resource)
      apply_route_target(changeset, target, transition_name, routes)
    end)
  end

  defp find_matching_target(routes, record, resource) do
    Enum.find_value(routes, fn route ->
      case Ash.Expr.eval(route.when, record: record, resource: resource) do
        {:ok, true} -> route.to
        _ -> nil
      end
    end)
  end

  defp apply_route_target(changeset, nil, transition_name, routes) do
    Ash.Changeset.add_error(
      changeset,
      "No matching condition for transition :#{transition_name}. " <>
        "Record did not match any of the #{length(routes)} configured routes."
    )
  end

  defp apply_route_target(changeset, target, _transition_name, _routes) do
    AshStateMachine.transition_state(changeset, target)
  end
end
