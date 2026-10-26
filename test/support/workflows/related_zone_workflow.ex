defmodule AshWorkflowTest.RelatedZoneWorkflow do
  @moduledoc """
  A wall-clock `every` whose `time_zone` comes from a related record rather
  than a column on the workflow itself.

  `time_zone` names an expression calculation, and the calculation reaches
  through the `candidate` relationship. That is the route to a zone stored
  somewhere else: the calculation does the reaching, so `time_zone` stays one
  name and the trigger's filter stays one expression.

      waiting ──(resolve)──▶ resolved
              │
              └─ at 09:00, in candidate.time_zone ──▶ (send_digest)
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    scheduler AshWorkflow.Scheduler.Precise

    step :waiting do
      transition :resolve, to: :resolved

      every :digest do
        at ~T[09:00:00]
        time_zone :candidate_time_zone
        action :send_digest
        last_fired_field :digest_fired_at
      end
    end

    step :resolved, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
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

    update :set_clock do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :digest_count, :integer, allow_nil?: false, default: 0, public?: true
  end

  relationships do
    belongs_to :candidate, AshWorkflowTest.Candidate do
      public? true
      attribute_writable? true
    end
  end

  calculations do
    calculate :candidate_time_zone, :string, expr(candidate.time_zone)
  end
end
