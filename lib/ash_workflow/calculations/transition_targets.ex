defmodule AshWorkflow.Calculations.TransitionTargets do
  @moduledoc """
  Ash calculation that maps each transition of a record's current step to the
  step it would move the record to, as `AshWorkflow.Info.transition_target/3`
  resolves it.

  The keys are the transitions the current step declares, the same list as
  `:available_actions` without an actor. The map is not filtered by
  authorization; load `:available_actions` with an actor for that.

  A transition resolves to `nil` when no route matches or a route fails to
  evaluate. A record in an automatic or terminal step gets an empty map.

  The calculation loads every field the route conditions reference, including
  fields on related resources. The transition action does not: it reads the
  record it is called on, where an unloaded relationship is `nil`. Call the
  action on a record with those fields loaded, or the two can disagree.

  Routes that read accepted input see none here, since a preview has no input.
  """
  use Ash.Resource.Calculation

  alias AshWorkflow.Info
  alias AshWorkflow.Routing

  @impl true
  @spec load(Ash.Query.t(), Keyword.t(), map()) :: list()
  def load(query, opts, _context) do
    references =
      opts
      |> Keyword.fetch!(:steps_map)
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.flat_map(&Info.transition(query.resource, &1).routes)
      |> Enum.flat_map(&Routing.references(&1.when, query.resource))
      |> Enum.map(&load_path/1)
      |> Enum.uniq()

    [Keyword.fetch!(opts, :state_attribute) | references]
  end

  @impl true
  @spec calculate([Ash.Resource.record()], Keyword.t(), map()) :: [map()]
  def calculate(records, opts, _context) do
    steps_map = Keyword.fetch!(opts, :steps_map)
    state_attribute = Keyword.fetch!(opts, :state_attribute)

    Enum.map(records, fn record ->
      steps_map
      |> Map.get(Map.get(record, state_attribute), [])
      |> Map.new(&{&1, target(record, &1)})
    end)
  end

  defp target(record, transition_name) do
    case Info.transition_target(record, transition_name) do
      {:ok, step} -> step
      {:error, _error} -> nil
    end
  end

  # `relationship.field` becomes `{:relationship, [:field]}`.
  defp load_path(%Ash.Query.Ref{relationship_path: path, attribute: attribute}) do
    List.foldr(path, field_name(attribute), &{&1, [&2]})
  end

  defp field_name(%{name: name}), do: name
  defp field_name(name) when is_atom(name), do: name
end
