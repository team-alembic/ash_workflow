defmodule AshWorkflowTest.ApprovalWorkflow do
  @moduledoc """
  Manual transitions workflow: a human reviews and approves or rejects.

  start → review ──(approve)──→ approved
                  └─(reject)───→ rejected
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step :review do
      manual true

      transition :approve, to: :approved
      transition :reject, to: :rejected
    end

    step :approved, terminal: true
    step :rejected, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false
  end
end
