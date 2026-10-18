defmodule AshWorkflowTest.RecipeFixtures.Invitation.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshWorkflowTest.RecipeFixtures.Invitation.Team
    resource AshWorkflowTest.RecipeFixtures.Invitation.User
  end
end
