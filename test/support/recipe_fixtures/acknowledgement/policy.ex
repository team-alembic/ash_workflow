defmodule AshWorkflowTest.RecipeFixtures.Acknowledgement.Policy do
  @moduledoc false
  use Ash.Resource,
    domain: AshWorkflowTest.RecipeFixtures.Acknowledgement.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:title]
    end

    update :revise do
      accept [:title]
      change set_attribute(:revised?, true)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :revised?, :boolean, default: false, public?: true
    timestamps()
  end
end
