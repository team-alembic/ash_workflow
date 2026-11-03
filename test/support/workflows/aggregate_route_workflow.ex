defmodule AshWorkflowTest.AggregateRouteWorkflow do
  @moduledoc """
  Workflow whose routes read an aggregate and a calculation built on it,
  neither of which is loaded on the record the transition is called on.

  screening ──(refer)──→ activated   (when sponsor_name == "Direct")
                       → compliance  (when sponsored?)
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :screening do
      transition :refer do
        route :activated, when: expr(sponsor_name == "Direct")
        route :compliance, when: expr(sponsored?)
      end
    end

    step :activated, terminal: true
    step :compliance, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    defaults [:read]

    create :create do
      accept [:sponsor_id]
    end
  end

  attributes do
    uuid_v7_primary_key :id
  end

  relationships do
    belongs_to :sponsor, AshWorkflowTest.Reviewer, public?: true
  end

  calculations do
    calculate :sponsored?, :boolean, expr(not is_nil(sponsor_name))
  end

  aggregates do
    first :sponsor_name, :sponsor, :name
  end
end
