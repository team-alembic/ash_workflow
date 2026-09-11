defmodule AshWorkflowTest.Workflow do
  @moduledoc false
  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :process_application do
      action :process_application
      on_success :review
    end

    step :review do
      transition :approve, to: :approved
      transition :reject, to: :rejected

      timeout :reminder, fire_after: {2, :days}, action: :send_reminder
      timeout :escalation, fire_after: {7, :days}, transition_to: :escalated
    end

    step :approved, terminal: true
    step :rejected, terminal: true
    step :escalated, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:candidate_name]
    end

    update :process_application do
      accept []
    end

    update :send_reminder do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :candidate_name, :string, allow_nil?: false, public?: true
  end
end
