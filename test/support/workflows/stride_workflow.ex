defmodule AshWorkflowTest.StrideWorkflow do
  @moduledoc """
  An `every` combining `interval` with `at`: 09:00 on a Monday, but only every
  second Monday.

  `on` says which days are occurrences and `interval` says how many local days
  must separate two fires. `AshWorkflowTest.WallClockWorkflow` covers `at`
  without a stride.

      waiting ──(resolve)──▶ resolved
              │
              └─ at 09:00 mon, every 14 local days ──▶ (send_digest)
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
        interval {14, :days}
        at ~T[09:00:00]
        on [:mon]
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
