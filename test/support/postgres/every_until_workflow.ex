defmodule AshWorkflowTest.Postgres.EveryUntilWorkflow do
  @moduledoc """
  An `every` bounded by `until`, against a real database and a real Oban
  trigger: reminders fire every hour and stop once the record has been in the
  step for 3 hours.

      waiting ──(resolve)──▶ resolved
              │
              └─ every hour ──▶ (send_reminder, until 3 hours)
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "every_until_workflows"
    repo(AshWorkflowTest.Repo)
  end

  workflow do
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
    define :submit
  end

  actions do
    defaults [:read]

    create :submit do
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
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :reminder_count, :integer, allow_nil?: false, default: 0, public?: true
  end
end
