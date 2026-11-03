defmodule AshWorkflowTest.SharedRoutedWorkflow do
  @moduledoc """
  Workflow where `:approve` has conditional routes in two steps, and each
  step's routes loop back to that step.

  start → pending ──(approve)──→ approved (when remaining <= 1)
                                → pending  (when remaining > 1)
                  └─(escalate)─→ overdue
        → overdue ──(approve)──→ approved (when remaining <= 1)
                                → overdue  (when remaining > 1)
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :pending do
      transition :approve do
        route :approved, when: expr(remaining <= 1)
        route :pending, when: expr(remaining > 1)
      end

      transition :escalate, to: :overdue
    end

    step :overdue do
      transition :approve do
        route :approved, when: expr(remaining <= 1)
        route :overdue, when: expr(remaining > 1)
      end
    end

    step :approved, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:remaining]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :remaining, :integer, allow_nil?: false, public?: true
  end
end
