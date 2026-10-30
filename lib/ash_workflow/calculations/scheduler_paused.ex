defmodule AshWorkflow.Calculations.SchedulerPaused do
  @moduledoc """
  Whether `AshWorkflow.Scheduler.pause/1` holds the scheduler on this node.

  `AshWorkflow.Scheduler.Oban` adds this to every workflow resource and to each
  generated trigger's `where`, so a paused node's poll finds no records and its
  workers find their record gone.
  """
  use Ash.Resource.Calculation

  # Read when the query runs, not when the trigger compiles, which is what lets
  # a `where` fixed at compile time follow a flag set at runtime.
  @impl true
  def expression(_opts, _context), do: AshWorkflow.Scheduler.paused?()
end
