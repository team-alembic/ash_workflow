defmodule AshWorkflowTest.RecipeFixtures.TransitionLog.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshWorkflowTest.RecipeFixtures.TransitionLog.Ticket
    resource AshWorkflowTest.RecipeFixtures.TransitionLog.Reviewer
  end
end
