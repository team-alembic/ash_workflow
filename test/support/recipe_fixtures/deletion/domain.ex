defmodule AshWorkflowTest.RecipeFixtures.Deletion.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshWorkflowTest.RecipeFixtures.Deletion.Account
  end
end
