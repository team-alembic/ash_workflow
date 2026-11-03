defmodule AshWorkflowTest.SignalListener do
  @moduledoc """
  Listens to `AshWorkflowTest.SignalWorkflow`'s `:approved` signal and fails
  for a record named "refuse", so a test can show a failing listener rolls the
  transition back.
  """
  use Ash.Resource, domain: AshWorkflowTest.Domain

  actions do
    action :check_approval do
      argument :signal, AshWorkflowTest.Signals.Approved, allow_nil?: false

      run fn input, _context ->
        if input.arguments.signal.name == "refuse",
          do: {:error, "approval refused"},
          else: :ok
      end
    end
  end

  signals_in do
    from AshWorkflowTest.Signals do
      on :approved, :check_approval
    end
  end
end
