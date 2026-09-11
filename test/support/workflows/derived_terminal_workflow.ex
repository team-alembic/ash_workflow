defmodule AshWorkflowTest.DerivedTerminalWorkflow do
  @moduledoc """
  Workflow where one end state is declared with `terminal: true` and the other
  declares nothing at all.

  Both are end states: a step with no action, no transitions, no timeouts, no
  on_success and no on_error has no way out.

  review ──(approve)──→ approved
         └─(reject)───→ rejected
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :review do
      transition :approve, to: :approved
      transition :reject, to: :rejected
    end

    step :approved
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
