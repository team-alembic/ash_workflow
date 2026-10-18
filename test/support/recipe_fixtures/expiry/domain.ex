defmodule AshWorkflowTest.RecipeFixtures.Expiry.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshWorkflowTest.RecipeFixtures.Expiry.Contract
  end
end
