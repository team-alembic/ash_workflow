defmodule AshWorkflowTest.Postgres.AtomicDefaultWorkflow do
  @moduledoc """
  Postgres-backed workflow whose actions leave `require_atomic?` at Ash's
  default, so the generated transition, the automatic step action and the
  timeout action must each run without an explicit `require_atomic? false`.

      checking ──on_success──▶ review ──(approve)──▶ approved
                                 ╰─ 1 day ─▶ send_reminder
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "atomic_default_workflows"
    repo(AshWorkflowTest.NoExprErrorRepo)
  end

  workflow do
    step :checking do
      action :run_checks
      on_success :review
    end

    step :review do
      transition :approve, to: :approved
      timeout :remind, fire_after: {1, :days}, action: :send_reminder
    end

    step :approved, terminal: true
  end

  code_interface do
    define :submit
  end

  actions do
    defaults [:read]

    create :submit do
      accept [:title]
    end

    update :run_checks do
      accept []
    end

    update :send_reminder do
      accept []
      change atomic_update(:reminders_sent, expr(reminders_sent + 1))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :title, :string, allow_nil?: false, public?: true
    attribute :reminders_sent, :integer, allow_nil?: false, default: 0, public?: true
  end
end
