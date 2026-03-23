defmodule AshWorkflowTest.RepeatingTimeoutWorkflow do
  @moduledoc """
  Workflow with a repeating timeout: sends follow-ups every 3 days.

  start → waiting ──(resolve)──→ resolved
                  │
                  └─ 3 days ──→ (send_follow_up, repeat every 3 days)
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step :waiting do
      manual true

      transition :resolve, to: :resolved

      timeout :follow_up, after: {3, :days}, action: :send_follow_up, repeat: true
    end

    step :resolved, terminal: true
  end

  actions do
    update :send_follow_up do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
