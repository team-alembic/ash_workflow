defmodule AshWorkflowTest.Postgres.ScreeningTransition do
  @moduledoc """
  The transition log for `AshWorkflowTest.Postgres.ScreeningWorkflow`.

  Exists to prove `RecordEvent` logs the target a conditional `on_success`
  route actually selected against a real database and a real Oban trigger —
  not just when the action is called directly.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "screening_transitions"
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
    belongs_to :workflow, AshWorkflowTest.Postgres.ScreeningWorkflow,
      allow_nil?: false,
      public?: true,
      attribute_public?: true,
      attribute_writable?: true
  end
end
