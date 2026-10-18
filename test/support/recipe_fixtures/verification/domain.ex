defmodule AshWorkflowTest.RecipeFixtures.Verification.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshWorkflowTest.RecipeFixtures.Verification.IdentityDocument
  end
end
