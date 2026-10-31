defmodule AshWorkflowTest.Signals do
  @moduledoc """
  Signals emitted by `AshWorkflowTest.SignalWorkflow`, and named by the
  `AshWorkflow.Verifiers.ValidateSignals` tests.

  The workflow signals declare the workflow fields so tests can assert on the
  values a workflow fills them with.
  """
  use Ash.Signals

  signals do
    signal :state_changed do
      argument :id, :uuid, allow_nil?: false
      argument :from_state, :atom
      argument :to_state, :atom, allow_nil?: false
      argument :transition_name, :atom
      argument :triggered_by, :atom, allow_nil?: false
      argument :occurred_at, :utc_datetime_usec, allow_nil?: false
    end

    signal :review_started do
      argument :id, :uuid, allow_nil?: false
      argument :to_state, :atom, allow_nil?: false
      argument :name, :string
    end

    signal :review_finished do
      argument :id, :uuid, allow_nil?: false
      argument :from_state, :atom
      argument :to_state, :atom, allow_nil?: false
    end

    signal :approved do
      argument :id, :uuid, allow_nil?: false
      argument :name, :string
      argument :verdict, :string, allow_nil?: false
      argument :transition_name, :atom
    end

    signal :escalated do
      argument :id, :uuid, allow_nil?: false
      argument :triggered_by, :atom
    end

    signal :reminded do
      argument :id, :uuid, allow_nil?: false
    end

    signal :nudged do
      argument :id, :uuid, allow_nil?: false
      argument :occurred_at, :utc_datetime_usec
    end

    signal :before_change do
      phase :before_action
      argument :id, :uuid
    end

    signal :needs_priority do
      argument :priority, :integer, allow_nil?: false
    end

    signal :string_state do
      argument :to_state, :string
    end
  end
end
