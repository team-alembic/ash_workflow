defmodule AshWorkflowTest.Postgres.OwnIndexWorkflow do
  @moduledoc """
  Postgres-backed workflow that declares its own index on the fields
  AshWorkflow would otherwise generate, for asserting the user's index wins
  rather than being duplicated.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "own_index_workflows"
    repo(AshWorkflowTest.Repo)

    custom_indexes do
      index([:state, :state_entered_at], unique: true)
    end
  end

  workflow do
    step :review do
      transition :approve, to: :approved

      timeout :escalation, fire_after: {2, :days}, transition_to: :escalated
    end

    step :approved, terminal: true
    step :escalated, terminal: true
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
