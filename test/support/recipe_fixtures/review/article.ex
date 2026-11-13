defmodule AshWorkflowTest.RecipeFixtures.Review.Article do
  @moduledoc false
  use Ash.Resource,
    domain: AshWorkflowTest.RecipeFixtures.Review.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:title, :body]
    end

    update :revise do
      accept [:body]
      change set_attribute(:revised?, true)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :body, :string, public?: true
    attribute :revised?, :boolean, default: false, public?: true
    timestamps()
  end
end
