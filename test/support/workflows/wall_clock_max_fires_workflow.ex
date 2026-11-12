defmodule AshWorkflowTest.WallClockMaxFiresWorkflow do
  @moduledoc """
  A wall-clock `every` bounded by `max_fires`, fired through
  `AshWorkflow.Scheduler.Precise`: 09:00 daily in Sydney, at most twice per
  step visit.
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
        time_zone "Australia/Sydney"
        action :send_digest
        max_fires(2)
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
      accept [:title]
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
end
