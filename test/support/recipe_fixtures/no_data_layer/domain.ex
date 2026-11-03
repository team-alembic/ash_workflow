defmodule AshWorkflowTest.RecipeFixtures.NoDataLayer.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshWorkflowTest.RecipeFixtures.NoDataLayer.User
  end
end
