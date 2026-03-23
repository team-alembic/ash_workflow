defmodule AshWorkflowTest.InitialFlagWorkflow do
  @moduledoc """
  Workflow where initial: true overrides declaration order.

  :draft is declared first (and would be the default initial state),
  but :review has initial: true so the workflow starts there.

  start → review ──(approve)──→ done
                  └─(revise)──→ draft ──(submit)──→ review
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step :draft do
      manual true
      transition :submit, to: :review
    end

    step :review do
      initial true
      manual true
      transition :approve, to: :done
      transition :revise, to: :draft
    end

    step :done, terminal: true
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false
  end
end
