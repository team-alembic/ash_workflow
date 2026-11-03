defmodule AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresTicket do
  @moduledoc false
  use Ash.Resource,
    domain: AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  # Listed in the test `:ash_domains` but never migrated, so test codegen
  # does not generate a migration for a fixture table.
  postgres do
    table "recipe_fixture_tickets"
    repo(AshWorkflowTest.Repo)
    migrate?(false)
  end

  workflow do
    step :open do
      transition :close, to: :closed
    end

    step :closed, terminal: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:title]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
