defmodule AshWorkflow.Calculations.CurrentStep do
  @moduledoc """
  Ash calculation that returns the name of the workflow's current step.

  Simply reads the workflow's state attribute — provided as a calculation for
  consistency and convenience when loading step-related data.
  """
  use Ash.Resource.Calculation

  @impl true
  @spec load(Ash.Query.t(), Keyword.t(), map()) :: [atom()]
  def load(_query, opts, _context), do: [Keyword.fetch!(opts, :state_attribute)]

  @impl true
  @spec calculate([Ash.Resource.record()], Keyword.t(), map()) :: [atom()]
  def calculate(records, opts, _context) do
    state_attribute = Keyword.fetch!(opts, :state_attribute)

    Enum.map(records, &Map.get(&1, state_attribute))
  end
end
