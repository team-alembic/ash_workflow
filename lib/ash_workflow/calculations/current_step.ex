defmodule AshWorkflow.Calculations.CurrentStep do
  @moduledoc """
  Ash calculation that returns the name of the workflow's current step.

  Simply reads the `:state` attribute — provided as a calculation for
  consistency and convenience when loading step-related data.
  """
  use Ash.Resource.Calculation

  @impl true
  @spec load(Ash.Query.t(), Keyword.t(), map()) :: [atom()]
  def load(_query, _opts, _context), do: [:state]

  @impl true
  @spec calculate([Ash.Resource.record()], Keyword.t(), map()) :: {:ok, [atom()]}
  def calculate(records, _opts, _context) do
    Enum.map(records, & &1.state)
  end
end
