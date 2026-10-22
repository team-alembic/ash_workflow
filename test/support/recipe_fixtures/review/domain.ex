defmodule AshWorkflowTest.RecipeFixtures.Review.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshWorkflowTest.RecipeFixtures.Review.Article
    resource AshWorkflowTest.RecipeFixtures.Review.Note
    resource AshWorkflowTest.RecipeFixtures.Review.User
  end
end
