defmodule AshWorkflowTest.RecipeFixtures.Approval.Expense do
  @moduledoc false
  use Ash.Resource,
    domain: AshWorkflowTest.RecipeFixtures.Approval.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:description, :amount]
    end

    update :adjust do
      accept [:amount]
      change set_attribute(:adjusted?, true)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :description, :string, allow_nil?: false, public?: true
    attribute :amount, :decimal, allow_nil?: false, public?: true
    attribute :adjusted?, :boolean, default: false, public?: true
    timestamps()
  end
end
