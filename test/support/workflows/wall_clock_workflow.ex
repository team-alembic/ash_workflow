defmodule AshWorkflowTest.WallClockWorkflow do
  @moduledoc """
  An `every` that fires at a wall-clock time in the record's own zone rather
  than on an interval: 09:00 on weekdays, in whatever `candidate_time_zone`
  holds.

  Uses `AshWorkflow.Scheduler.Precise`, which computes the occurrence in
  Elixir through `AshWorkflow.WallClock` and so runs on the Ets data layer.
  The polled Oban trigger's `where` clause is a Postgres fragment instead, and
  `AshWorkflowTest.Postgres.WallClockWorkflow` covers that side.

  `set_clock` is a plain update action outside the workflow, so a test can
  move `state_entered_at` and `digest_fired_at` to either side of an
  occurrence without waiting for a real clock.

      waiting ──(resolve)──▶ resolved
              │
              └─ at 09:00 mon-fri, in candidate_time_zone ──▶ (send_digest)
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
        on [:mon, :tue, :wed, :thu, :fri]
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

    update :set_clock do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :candidate_time_zone, :string, allow_nil?: false, public?: true
    attribute :digest_count, :integer, allow_nil?: false, default: 0, public?: true
  end
end
