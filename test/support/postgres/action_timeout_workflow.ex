defmodule AshWorkflowTest.Postgres.ActionTimeoutWorkflow do
  @moduledoc """
  Action timeouts against a real database and a real Oban trigger.

      waiting ──(leave)──▶ away ──(come_back)──▶ waiting
                              └──(finish)──▶ done

  `:reminder` runs `send_reminder` an hour after the record enters `:waiting`.
  `:check` runs `run_check` once `next_check_at` has passed, and `run_check`
  moves `next_check_at` an hour later, which is the periodic check the
  timeouts guide describes. `:ping` runs `ping` three hours after entry, and
  `ping` is fully atomic, so it fires through
  `AshWorkflow.Changes.RecordEvent.atomic/3`. None of the actions change
  state.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "action_timeout_workflows"
    repo(AshWorkflowTest.Repo)
  end

  workflow do
    step :waiting do
      transition :leave, to: :away

      timeout :reminder, fire_after: {1, :hours}, action: :send_reminder

      timeout :ping, fire_after: {3, :hours}, action: :ping

      timeout :check do
        fire_at :next_check_at
        action :run_check
      end
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
      accept [:next_check_at]
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

    update :ping do
      change atomic_update(:pings, expr(pings + 1))
    end

    update :run_check do
      require_atomic? false

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:checks, changeset.data.checks + 1)
        |> Ash.Changeset.force_change_attribute(
          :next_check_at,
          DateTime.add(DateTime.utc_now(), 1, :hour)
        )
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :reminders, :integer, allow_nil?: false, default: 0, public?: true
    attribute :pings, :integer, allow_nil?: false, default: 0, public?: true
    attribute :checks, :integer, allow_nil?: false, default: 0, public?: true
    attribute :next_check_at, :utc_datetime_usec, public?: true
  end
end
