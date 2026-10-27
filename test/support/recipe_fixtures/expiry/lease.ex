defmodule AshWorkflowTest.RecipeFixtures.Expiry.Lease do
  @moduledoc false
  use Ash.Resource,
    domain: AshWorkflowTest.RecipeFixtures.Expiry.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, create: [:id]]
  end

  attributes do
    # ETS generates no keys, so the caller supplies one.
    integer_primary_key :id, writable?: true, generated?: false
  end
end
