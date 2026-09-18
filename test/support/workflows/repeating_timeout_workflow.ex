defmodule AshWorkflowTest.RepeatingTimeoutWorkflow do
  @moduledoc """
  Workflow with a recurring action: sends follow-ups every 3 days.

  start → waiting ──(resolve)──→ resolved
                  │
                  └─ every 3 days ──→ send_follow_up
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :waiting do
      transition :resolve, to: :resolved

      every :follow_up, {3, :days}, action: :send_follow_up
    end

    step :resolved, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title]
    end

    update :send_follow_up do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
