defmodule AshWorkflowTest.Postgres.ApprovalWorkflow do
  @moduledoc """
  Postgres-backed workflow covering an automatic step, a manual step and a
  timeout, so the Oban integration tests can drive each kind of trigger
  against a real queue.

      draft ──(submit)──▶ processing ──on_success──▶ review ──(approve)──▶ approved
                             │                        │      ╰─(reject)──▶ rejected
                             ╰──on_error──▶ failed    ╰─ 2 days ─▶ escalated
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow]

  postgres do
    table "approval_workflows"
    repo(AshWorkflowTest.Repo)
  end

  workflow do
    step :processing do
      action :process
      on_success :review
      on_error :failed
    end

    step :review do
      transition :approve, to: :approved
      transition :reject, to: :rejected

      timeout :escalation, after: {2, :days}, transition_to: :escalated
    end

    step :approved, terminal: true
    step :rejected, terminal: true
    step :escalated, terminal: true
    step :failed, terminal: true
  end

  code_interface do
    define :submit, action: :submit
  end

  actions do
    defaults [:read]

    create :submit do
      accept [:title, :should_fail]
    end

    update :process do
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        if Ash.Changeset.get_attribute(changeset, :should_fail) do
          Ash.Changeset.add_error(changeset, field: :title, message: "processing failed")
        else
          Ash.Changeset.change_attribute(changeset, :processed_at, DateTime.utc_now())
        end
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :title, :string, allow_nil?: false, public?: true
    attribute :should_fail, :boolean, allow_nil?: false, default: false, public?: true
    attribute :processed_at, :utc_datetime_usec, public?: true
  end
end
