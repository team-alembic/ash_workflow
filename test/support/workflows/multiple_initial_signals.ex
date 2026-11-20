defmodule AshWorkflowTest.MultipleInitialSignals do
  @moduledoc """
  Signals emitted by `AshWorkflowTest.MultipleInitialRuntimeWorkflow` on entering
  its initial steps.
  """
  use Ash.Signals

  signals do
    signal :drafting_started do
      argument :id, :uuid, allow_nil?: false
      argument :to_state, :atom, allow_nil?: false
    end

    signal :intake_started do
      argument :id, :uuid, allow_nil?: false
      argument :to_state, :atom, allow_nil?: false
    end
  end
end
