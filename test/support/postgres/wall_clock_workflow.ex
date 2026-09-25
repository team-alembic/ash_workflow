defmodule AshWorkflowTest.Postgres.WallClockWorkflow do
  @moduledoc """
  An `every` that fires at a wall-clock time in the record's own zone, against
  a real database and a real Oban trigger.

  This is the side `AshWorkflowTest.WallClockWorkflow` cannot cover: the
  trigger's `where` clause is a Postgres fragment doing the
  `AT TIME ZONE` arithmetic per row, because `candidate_time_zone` is read out
  of the row rather than out of the DSL.

      waiting ──(resolve)──▶ resolved
              │
              └─ at 09:00 mon-fri, in candidate_time_zone ──▶ (send_digest)
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "wall_clock_workflows"
    repo(AshWorkflowTest.Repo)
  end

  workflow do
    step :waiting do
      transition :resolve, to: :resolved

      every :digest do
        at ~T[09:00:00]
        on [:mon, :tue, :wed, :thu, :fri]
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
