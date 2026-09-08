defmodule AshWorkflowTest.Postgres.ScreeningWorkflow do
  @moduledoc """
  Postgres-backed workflow with an automatic step whose `on_success` is a set
  of conditional entries, so the Oban integration tests can prove a record
  takes different paths based on what the step's own action computed —
  not just that the DSL compiles.

      screening ──(run_screening, score >= 5)──▶ interview
                └─(run_screening, score < 5)───▶ rejected_by_hr
                └─(run_screening, error)────────▶ screening_failed
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow]

  postgres do
    table "screening_workflows"
    repo(AshWorkflowTest.Repo)
  end

  workflow do
    transition_log AshWorkflowTest.Postgres.ScreeningTransition

    step :screening do
      action :run_screening

      on_success :interview, when: expr(screen_score >= 5)
      on_success :rejected_by_hr, when: expr(screen_score < 5)

      on_error :screening_failed
    end

    step :interview, terminal: true
    step :rejected_by_hr, terminal: true
    step :screening_failed, terminal: true
  end

  code_interface do
    define :submit
  end

  actions do
    defaults [:read]

    create :submit do
      accept [:candidate_name, :should_fail]
    end

    update :run_screening do
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        cond do
          Ash.Changeset.get_attribute(changeset, :should_fail) ->
            Ash.Changeset.add_error(changeset,
              field: :candidate_name,
              message: "screening failed"
            )

          Ash.Changeset.get_attribute(changeset, :candidate_name) == "Strong Candidate" ->
            Ash.Changeset.change_attribute(changeset, :screen_score, 8)

          true ->
            Ash.Changeset.change_attribute(changeset, :screen_score, 2)
        end
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :candidate_name, :string, allow_nil?: false, public?: true
    attribute :should_fail, :boolean, allow_nil?: false, default: false, public?: true
    attribute :screen_score, :integer, public?: true
  end
end
