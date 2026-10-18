defmodule AshWorkflowTest.RecipeFixtures.Dormancy.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshWorkflowTest.RecipeFixtures.Dormancy.Account
  end
end
