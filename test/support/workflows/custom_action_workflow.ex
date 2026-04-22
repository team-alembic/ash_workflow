defmodule AshWorkflowTest.CustomActionWorkflow do
  @moduledoc """
  Tests that user-defined actions for transitions get the transition_state
  and state_entered_at changes merged in by the transformer, rather than
  being silently skipped.

  start → review ──(approve)──→ approved  (user-defined with extra timestamp)
                  └─(reject)───→ rejected (user-defined with accept [:reason])
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step :review do
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

    update :approve do
      accept []
      change set_attribute(:approved_at, &DateTime.utc_now/0)
    end

    update :reject do
      accept [:reason]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false
    attribute :approved_at, :utc_datetime_usec
    attribute :reason, :string
  end
end
