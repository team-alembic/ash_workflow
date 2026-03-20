defmodule AshWorkflowTest.LoopbackWorkflow do
  @moduledoc """
  Workflow with a loop-back: a step can return to an earlier step.

  start → draft → review ──(approve)──→ published
                          └─(revise)───→ draft  (loop back)
                          └─(reject)───→ rejected

  The draft→review→draft cycle can repeat any number of times.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshStateMachine]

  workflow do
    step :draft do
      manual true

      transition :submit, to: :review
    end

    step :review do
      manual true

      transition :approve, to: :published
      transition :revise, to: :draft
      transition :reject, to: :rejected
    end

    step :published, terminal: true
    step :rejected, terminal: true
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false
    attribute :revision_count, :integer, default: 0
  end
end
