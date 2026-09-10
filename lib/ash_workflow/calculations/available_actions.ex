defmodule AshWorkflow.Calculations.AvailableActions do
  @moduledoc """
  Ash calculation that returns the list of user-facing actions available
  for a workflow record's current step.

  When an actor is present in the context, filters the list to only actions
  the actor is authorized to perform.
  """
  use Ash.Resource.Calculation

  @impl true
  @spec load(Ash.Query.t(), Keyword.t(), map()) :: [atom()]
  def load(_query, opts, _context), do: [Keyword.fetch!(opts, :state_attribute)]

  @impl true
  @spec calculate([Ash.Resource.record()], Keyword.t(), map()) :: [[atom()]]
  def calculate(records, opts, context) do
    steps_map = Keyword.fetch!(opts, :steps_map)
    state_attribute = Keyword.fetch!(opts, :state_attribute)

    Enum.map(records, fn record ->
      steps_map
      |> Map.get(Map.get(record, state_attribute), [])
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
