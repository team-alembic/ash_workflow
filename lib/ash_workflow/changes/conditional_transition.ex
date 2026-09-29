defmodule AshWorkflow.Changes.ConditionalTransition do
  @moduledoc """
  An Ash change that evaluates conditional routes at runtime to determine the
  transition target.

  Routes are evaluated in order. The first route whose `when` expression matches
  wins. If no route matches, the changeset gets an error.

  Conditions are evaluated against the record as it was loaded, with the
  transition's accepted input applied on top, so a route can branch on a value
  the same call supplied:

      transition :decide do
        accept [:decision]
        route :approved, when: expr(decision == :approve)
        route :rejected, when: expr(decision == :reject)
      end

  Only the attributes named in `accept` are applied. An attribute written by
  one of the action's own changes is not, so a route still sees the state the
  record was in when the call arrived. That is what lets a transition decide
  "has anyone approved before this call?" while the same action records the
  current approver:

      transition :approve do
        route :approved, when: expr(not is_nil(first_approver_id))
        route :in_review, when: expr(is_nil(first_approver_id))
      end

  `first_approver_id` is set by a change on `:approve`, not accepted from the
  caller, so the first approver reads `nil` and loops back to `:in_review`.

  This differs from `AshWorkflow.Changes.ConditionalOnSuccess`, which applies
  every attribute the changeset carries. An automatic step has no caller
  supplying input, so the only thing its routes could branch on is what its
  action computed.

  `AshWorkflow.Info.transition_target/3` resolves routes the same way, so it
  previews where this change would send a record.

  Used internally by the AddActions transformer for transitions with conditional
  routes. Not intended for direct use.
  """
  use Ash.Resource.Change

  alias AshWorkflow.Routing
  alias AshWorkflow.Telemetry

  @impl true
  def change(changeset, opts, _context) do
    routes = opts[:routes]
    transition_name = opts[:transition_name]
    accept = opts[:accept] || []
    resource = changeset.resource

    Ash.Changeset.before_action(changeset, fn changeset ->
      # Only accepted input, not every pending change: a route must still see
      # the state before this call when one of the action's changes writes to it.
      record = Routing.with_input(changeset.data, changeset.attributes, accept)
      result = Routing.match(routes, record, resource)

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

        :no_match ->
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
end
