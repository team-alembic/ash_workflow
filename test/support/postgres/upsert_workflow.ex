defmodule AshWorkflowTest.Postgres.UpsertWorkflow do
  @moduledoc """
  Postgres-backed logged workflow whose create action upserts on an identity,
  so a second create for the same code takes the `ON CONFLICT DO UPDATE`
  branch and returns the existing row.

      open ──(close)──▶ closed
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "upsert_workflows"
    repo(AshWorkflowTest.Repo)
  end

  workflow do
    transition_log AshWorkflowTest.Postgres.UpsertTransition

    step :open do
      transition :close, to: :closed
    end

    step :closed, terminal: true
  end

  actions do
    defaults [:read]

    create :open do
      accept [:code]
      upsert? true
      upsert_identity :unique_code
      upsert_fields [:code]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_code, [:code]
  end
end
