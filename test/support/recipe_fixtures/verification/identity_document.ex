defmodule AshWorkflowTest.RecipeFixtures.Verification.IdentityDocument do
  @moduledoc false
  use Ash.Resource,
    domain: AshWorkflowTest.RecipeFixtures.Verification.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:number]
    end

    update :correct do
      accept [:number]
      change set_attribute(:corrected?, true)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :number, :string, allow_nil?: false, public?: true
    attribute :corrected?, :boolean, default: false, public?: true
    timestamps()
  end
end
