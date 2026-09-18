defmodule AshWorkflowTest.Postgres.FireAtWorkflow do
  @moduledoc """
  A `fire_at` timeout against a real database and a real Oban trigger.

      pending ──(expires_at passes)──▶ expired
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "fire_at_workflows"
    repo(AshWorkflowTest.Repo)
  end

  workflow do
    step :pending do
      transition :accept, to: :accepted

      timeout :expire do
        fire_at :expires_at
        transition_to :expired
      end
    end

    step :accepted, terminal: true
    step :expired, terminal: true
  end

  code_interface do
    define :offer
  end

  actions do
    defaults [:read]

    create :offer do
      accept [:candidate_name, :expires_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :candidate_name, :string, allow_nil?: false, public?: true
    attribute :expires_at, :utc_datetime_usec, public?: true
  end
end
