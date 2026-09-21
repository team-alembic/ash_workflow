defmodule AshWorkflowTest.EveryUntilWorkflow do
  @moduledoc """
  An `every` bounded by `until`: reminders fire every hour and stop once the
  record has been in the step for 3 hours.

  Uses `AshWorkflow.Scheduler.Precise` so `Precise.run_due/2` can drive the
  timeout synchronously, and `set_clock` (a plain update action outside the
  workflow) so a test can move `state_entered_at` — the one anchor `interval`
  and `until` both ultimately depend on, now that firing writes its own
  column instead of resetting `state_entered_at`.

      waiting ──(resolve)──▶ resolved
              │
              └─ every hour ──▶ (send_reminder, until 3 hours)
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    scheduler AshWorkflow.Scheduler.Precise

    step :waiting do
      transition :resolve, to: :resolved

      every :reminder do
        interval {1, :hours}
        action :send_reminder
        until {3, :hours}
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

    # `state_entered_at` is not writable, so it is forced in rather than
    # accepted. See `AshWorkflow.Transformers.AddAttributes`.
    update :set_clock do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :reminder_count, :integer, allow_nil?: false, default: 0, public?: true
  end
end
