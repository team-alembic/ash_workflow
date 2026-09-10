defmodule AshWorkflowTest.AcceptedRouteWorkflow do
  @moduledoc """
  Workflow where a manual transition routes on the input it accepts.

  `:decide` accepts `:decision` and branches on it in the same call, which is
  the shape most decision steps take: submit the outcome, and route on the
  outcome. It also covers the case where a route reads an attribute the call
  did not touch, which still comes from the record as it was loaded.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :review do
      transition :decide do
        accept [:decision]
        route :approved, when: expr(decision == :approve)
        route :rejected, when: expr(decision == :reject)
      end

      transition :escalate do
        accept [:decision]
        route :approved, when: expr(priority == :urgent)
        route :rejected, when: expr(priority == :normal)
      end
    end

    step :approved, terminal: true
    step :rejected, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title, :decision, :priority]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false

    attribute :decision, :atom,
      allow_nil?: true,
      constraints: [one_of: [:approve, :reject]],
      public?: true

    attribute :priority, :atom,
      allow_nil?: true,
      constraints: [one_of: [:urgent, :normal]],
      public?: true
  end
end
