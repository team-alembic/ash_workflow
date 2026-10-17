defmodule AshWorkflowTest.PreciseActionTimeoutWorkflow do
  @moduledoc """
  Action timeouts under `AshWorkflow.Scheduler.Precise`, measured against a
  field the test writes.

  Both timeouts run `send_reminder`, which adds 1 to `reminders` and leaves
  the record in `:waiting`. Setting `deadline_from` 5 seconds ago makes
  `:reminder` due and leaves `:final_reminder` 55 seconds out. Setting it
  59.5 seconds ago makes `:reminder` due and `:final_reminder` due half a
  second later.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    scheduler AshWorkflow.Scheduler.Precise

    step :waiting do
      transition :finish, to: :done

      timeout :reminder, fire_after: {1, :seconds}, field: :deadline_from, action: :send_reminder

      timeout :final_reminder,
        fire_after: {60, :seconds},
        field: :deadline_from,
        action: :send_reminder
    end

    step :done, terminal: true
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:deadline_from]
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
    attribute :deadline_from, :utc_datetime_usec, public?: true
    attribute :reminders, :integer, allow_nil?: false, default: 0, public?: true
  end
end
