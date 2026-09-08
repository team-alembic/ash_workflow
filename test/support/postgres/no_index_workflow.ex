defmodule AshWorkflowTest.Postgres.NoIndexWorkflow do
  @moduledoc """
  Postgres-backed workflow that opts out of generated indexes, for asserting
  `generate_indexes? false` leaves `custom_indexes` empty.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "no_index_workflows"
    repo(AshWorkflowTest.Repo)
  end

  workflow do
    generate_indexes?(false)

    step :review do
      transition :approve, to: :approved

      timeout :escalation, after: {2, :days}, transition_to: :escalated
    end

    step :approved, terminal: true
    step :escalated, terminal: true
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
