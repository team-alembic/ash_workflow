defmodule AshWorkflowTest.Postgres.ScreeningWithTimeoutWorkflow do
  @moduledoc """
  `ScreeningWorkflow`'s conditional `on_success` routing, plus a timeout on
  the same step — so the Oban integration tests can prove the two features
  don't interfere: the timeout still fires for a record that hasn't been
  routed yet, and `on_success` routing still works on a step that also
  declares a timeout.

      screening ──(run_screening, score >= 5)──▶ interview
                └─(run_screening, score < 5)───▶ rejected_by_hr
                └─(1 hour, unrouted)────────────▶ escalated
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "screening_with_timeout_workflows"
    repo(AshWorkflowTest.Repo)
  end

  workflow do
    step :screening do
      action :run_screening

      on_success :interview, when: expr(screen_score >= 5)
      on_success :rejected_by_hr, when: expr(screen_score < 5)

      timeout :sla, fire_after: {1, :hours}, transition_to: :escalated
    end

    step :interview, terminal: true
    step :rejected_by_hr, terminal: true
    step :escalated, terminal: true
  end

  code_interface do
    define :submit
  end

  actions do
    defaults [:read]

    create :submit do
      accept [:candidate_name]
    end

    update :run_screening do
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        if Ash.Changeset.get_attribute(changeset, :candidate_name) == "Strong Candidate" do
          Ash.Changeset.change_attribute(changeset, :screen_score, 8)
        else
          Ash.Changeset.change_attribute(changeset, :screen_score, 2)
        end
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :candidate_name, :string, allow_nil?: false, public?: true
    attribute :screen_score, :integer, public?: true
  end
end
