defmodule AshWorkflowTest.RecipeFixtures.Review.Note do
  @moduledoc false
  use Ash.Resource,
    domain: AshWorkflowTest.RecipeFixtures.Review.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, create: [:id, :text]]
  end

  attributes do
    # ETS generates no keys, so the caller supplies one.
    integer_primary_key :id, writable?: true, generated?: false
    attribute :text, :string, public?: true
  end
end
