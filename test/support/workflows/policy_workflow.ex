defmodule AshWorkflowTest.PolicyWorkflow do
  @moduledoc """
  Workflow with step-level authorization: only managers can approve.

  start → manager_review ──(approve)──→ approved   (only role: :manager)
                          └─(reject)───→ rejected   (only role: :manager)
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :manager_review do
      policy actor_attribute_equals(:role, :manager)

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
