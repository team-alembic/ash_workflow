defmodule AshWorkflow.Calculations.Steps do
  @moduledoc """
  Ash calculation that returns the list of all workflow step names.

  This is static data derived from the DSL — the same for every record.
  """
  use Ash.Resource.Calculation

  @impl true
  @spec calculate([Ash.Resource.record()], Keyword.t(), map()) :: [[atom()]]
  def calculate(records, opts, _context) do
    step_names = Keyword.fetch!(opts, :step_names)
    Enum.map(records, fn _record -> step_names end)
  end
end
