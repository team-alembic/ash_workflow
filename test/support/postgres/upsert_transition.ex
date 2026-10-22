defmodule AshWorkflowTest.Postgres.UpsertTransition do
  @moduledoc """
  The transition log for `AshWorkflowTest.Postgres.UpsertWorkflow`.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "upsert_transitions"
    repo(AshWorkflowTest.Repo)
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :workflow_id,
        :from_state,
        :to_state,
        :transition_name,
        :occurred_at,
        :triggered_by
      ]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :from_state, :atom, public?: true
    attribute :to_state, :atom, allow_nil?: false, public?: true
    attribute :transition_name, :atom, allow_nil?: false, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :triggered_by, :atom, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :workflow, AshWorkflowTest.Postgres.UpsertWorkflow,
      allow_nil?: false,
      public?: true,
      attribute_public?: true,
      attribute_writable?: true
  end
end
