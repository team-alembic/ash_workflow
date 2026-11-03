defmodule AshWorkflowTest.RecipeFixtures.Expiry.Contract do
  @moduledoc false
  use Ash.Resource,
    domain: AshWorkflowTest.RecipeFixtures.Expiry.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:title]
    end

    update :rename do
      accept [:title]
      change set_attribute(:renamed?, true)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :renamed?, :boolean, default: false, public?: true
    timestamps()
  end
end
