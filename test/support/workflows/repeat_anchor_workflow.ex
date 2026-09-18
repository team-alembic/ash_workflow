defmodule AshWorkflowTest.RepeatAnchorWorkflow do
  @moduledoc """
  A repeating timeout whose bound is anchored on the record rather than on the
  step: reminders fire every hour and stop 3 hours after `signed_up_at`,
  wherever the record has been in between.

  The anchor is what distinguishes this from
  `AshWorkflowTest.RepeatUntilWorkflow`, which leaves `field` unset and so
  measures its bound against the `repeat_started_at` the extension maintains.
  Naming an anchor means this resource needs no `repeat_started_at` attribute
  at all, which one of its tests asserts.

      waiting ──(resolve)──▶ resolved
              │
              └─ 1 hour ──▶ (send_reminder, repeat hourly, until 3h after signup)
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    scheduler AshWorkflow.Scheduler.Precise

    step :waiting do
      transition :resolve, to: :resolved

      timeout :reminder do
        fire_after {1, :hours}
        action :send_reminder

        repeat true do
          until {3, :hours}
          field :signed_up_at
        end
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
      accept [:title, :signed_up_at]
    end

    update :send_reminder do
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        Ash.Changeset.change_attribute(
          changeset,
          :reminder_count,
          Ash.Changeset.get_data(changeset, :reminder_count) + 1
        )
      end
    end

    update :set_clock do
      accept [:state_entered_at, :signed_up_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :signed_up_at, :utc_datetime_usec, public?: true
    attribute :reminder_count, :integer, allow_nil?: false, default: 0, public?: true
  end
end
