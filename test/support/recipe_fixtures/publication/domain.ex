defmodule AshWorkflowTest.RecipeFixtures.Publication.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshWorkflowTest.RecipeFixtures.Publication.Post
  end
end
