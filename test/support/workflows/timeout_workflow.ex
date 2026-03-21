defmodule AshWorkflowTest.TimeoutWorkflow do
  @moduledoc """
  Workflow with timeouts: a reminder fires after inactivity, then escalation forces a transition.

  start → waiting ──(resolve)──→ resolved
                  │
                  ├─ 2 days ──→ (send_reminder action, stay in :waiting)
                  └─ 7 days ──→ escalated
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step :waiting do
      manual true

      transition :resolve, to: :resolved

      timeout :reminder, after: {2, :days}, action: :send_reminder
      timeout :escalation, after: {7, :days}, transition_to: :escalated
    end

    step :resolved, terminal: true
    step :escalated, terminal: true
  end

  actions do
    update :send_reminder do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
