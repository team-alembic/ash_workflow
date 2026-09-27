defmodule AshWorkflowTest.Postgres.RelatedZoneWorkflow do
  @moduledoc """
  A wall-clock `every` whose zone comes from a related record, against a real
  database and a real Oban trigger.

  `time_zone` names an expression calculation reaching through the `candidate`
  relationship, so the trigger's `where` clause has to inline that calculation
  and join. That is the part only Postgres can answer, and the reason
  `AshWorkflow.Verifiers.ValidateEvery` rejects a module calculation here.

      waiting ──(resolve)──▶ resolved
              │
              └─ at 09:00, in candidate.time_zone ──▶ (send_digest)
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "related_zone_workflows"
    repo(AshWorkflowTest.Repo)
  end

  workflow do
    step :waiting do
      transition :resolve, to: :resolved

      every :digest do
        at ~T[09:00:00]
        time_zone :candidate_time_zone
        action :send_digest
      end
    end

    step :resolved, terminal: true
  end

  code_interface do
    define :submit
  end

  actions do
    defaults [:read]

    create :submit do
      accept [:title, :candidate_id]
    end

    update :send_digest do
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        Ash.Changeset.change_attribute(
          changeset,
          :digest_count,
          Ash.Changeset.get_data(changeset, :digest_count) + 1
        )
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :digest_count, :integer, allow_nil?: false, default: 0, public?: true
  end

  relationships do
    belongs_to :candidate, AshWorkflowTest.Postgres.Candidate do
      public? true
      attribute_writable? true
      allow_nil? false
    end
  end

  calculations do
    calculate :candidate_time_zone, :string, expr(candidate.time_zone)
  end
end
