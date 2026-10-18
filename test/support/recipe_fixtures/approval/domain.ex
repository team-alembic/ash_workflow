defmodule AshWorkflowTest.RecipeFixtures.Approval.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshWorkflowTest.RecipeFixtures.Approval.Expense
    resource AshWorkflowTest.RecipeFixtures.Approval.User
  end
end
