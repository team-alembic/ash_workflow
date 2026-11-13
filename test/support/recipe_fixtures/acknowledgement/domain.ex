defmodule AshWorkflowTest.RecipeFixtures.Acknowledgement.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshWorkflowTest.RecipeFixtures.Acknowledgement.Policy
    resource AshWorkflowTest.RecipeFixtures.Acknowledgement.User
  end
end
