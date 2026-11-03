defmodule AshWorkflowTest.RecipeFixtures.NoDataLayer.User do
  @moduledoc false
  use Ash.Resource, domain: AshWorkflowTest.RecipeFixtures.NoDataLayer.Domain

  attributes do
    uuid_v7_primary_key :id
  end
end
