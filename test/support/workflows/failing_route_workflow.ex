defmodule AshWorkflowTest.FailingRouteWorkflow do
  @moduledoc """
  Workflow designed to test conditional route error paths.

  The :decide transition has routes that only match specific values,
  allowing tests to trigger the no-match error path.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step :pending do
      transition :decide do
        route :approved, when: expr(category == :good)
        route :rejected, when: expr(category == :bad)
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
      accept [:title, :category]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false

    attribute :category, :atom,
      allow_nil?: true,
      constraints: [one_of: [:good, :bad, :unknown]],
      public?: true
  end
end
