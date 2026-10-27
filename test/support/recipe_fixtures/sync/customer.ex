defmodule AshWorkflowTest.RecipeFixtures.Sync.Customer do
  @moduledoc false
  use Ash.Resource,
    domain: AshWorkflowTest.RecipeFixtures.Sync.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:name]
    end

    update :rename do
      accept [:name]
      change set_attribute(:renamed?, true)
    end

    update :annotate do
      accept [:notes]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :renamed?, :boolean, default: false, public?: true
    attribute :notes, :string, public?: true
    timestamps()
  end
end
