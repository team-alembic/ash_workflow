defmodule AshWorkflowTest.Postgres.StrideWorkflow do
  @moduledoc """
  An `interval` combined with `at`, against a real database and a real Oban
  trigger: 09:00 on a Monday, every second Monday.

  The stride reaches SQL as a `date - date` comparison rather than a duration,
  which is the part worth exercising against Postgres itself.

      waiting ──(resolve)──▶ resolved
              │
              └─ at 09:00 mon, every 14 local days ──▶ (send_digest)
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "stride_workflows"
    repo(AshWorkflowTest.Repo)
  end

  workflow do
    step :waiting do
      transition :resolve, to: :resolved

      every :digest do
        interval {14, :days}
        at ~T[09:00:00]
        on [:mon]
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
      accept [:title, :candidate_time_zone]
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
    attribute :candidate_time_zone, :string, allow_nil?: false, public?: true
    attribute :digest_count, :integer, allow_nil?: false, default: 0, public?: true
  end
end
