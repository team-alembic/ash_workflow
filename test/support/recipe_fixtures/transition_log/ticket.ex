defmodule AshWorkflowTest.RecipeFixtures.TransitionLog.Ticket do
  @moduledoc false
  use Ash.Resource,
    domain: AshWorkflowTest.RecipeFixtures.TransitionLog.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :open do
      transition :close, to: :closed
    end

    step :closed, terminal: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:title]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
