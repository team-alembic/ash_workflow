defmodule AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresTicket
  end
end
