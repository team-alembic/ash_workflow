defmodule AshWorkflowTest.PreciseRevisitWorkflow do
  @moduledoc """
  An action timeout under `AshWorkflow.Scheduler.Precise` measured from
  `state_entered_at`, with a way out of the step and back in.

      waiting ──(leave)──▶ away ──(come_back)──▶ waiting

  `:reminder` runs `send_reminder` one second after each entry into
  `:waiting`. A test waits for the deadline in real time, so the second visit
  starts after the first firing, as it would in production.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    scheduler AshWorkflow.Scheduler.Precise

    step :waiting do
      transition :leave, to: :away
      timeout :reminder, fire_after: {1, :seconds}, action: :send_reminder
    end

    step :away do
      transition :come_back, to: :waiting
      transition :finish, to: :done
    end

    step :done, terminal: true
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept []
    end

    update :send_reminder do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :reminders,
          changeset.data.reminders + 1
        )
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :reminders, :integer, allow_nil?: false, default: 0, public?: true
  end
end
