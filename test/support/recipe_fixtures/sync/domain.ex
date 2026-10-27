defmodule AshWorkflowTest.RecipeFixtures.Sync.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshWorkflowTest.RecipeFixtures.Sync.Customer
  end
end
