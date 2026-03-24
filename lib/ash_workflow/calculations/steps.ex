defmodule AshWorkflow.Calculations.Steps do
  @moduledoc """
  Ash calculation that returns the list of all workflow step names.

  This is static data derived from the DSL — the same for every record.
  """
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, opts, _context) do
    step_names = opts[:step_names]
    Enum.map(records, fn _record -> step_names end)
  end
end
