defmodule AshWorkflow.Calculations.AvailableActions do
  @moduledoc """
  Ash calculation that returns the list of user-facing actions available
  for a workflow record's current step.

  When an actor is present in the context, filters the list to only actions
  the actor is authorized to perform.
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:state]

  @impl true
  def calculate(records, opts, context) do
    steps_map = opts[:steps_map]

    Enum.map(records, fn record ->
      steps_map
      |> Map.get(record.state, [])
      |> maybe_filter_by_auth(record, context)
    end)
  end

  defp maybe_filter_by_auth(actions, _record, %{actor: nil}), do: actions

  defp maybe_filter_by_auth(actions, record, %{actor: actor}) do
    Enum.filter(actions, fn action_name ->
      Ash.can?({record, action_name}, actor)
    end)
  end
end
