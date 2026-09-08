defmodule AshWorkflowTest.Postgres.AuthorizedScreeningWorkflow do
  @moduledoc """
  `ScreeningWorkflow`'s conditional `on_success` routing, but on a resource
  with an authorizer and a step-level policy elsewhere in the workflow — the
  combination `FullPipeline` exercises for unconditional `on_success`, and
  `AuthorizedErrorPathWorkflow` exercises for `on_error`, but nothing exercises
  for a *conditional* `on_success` driven through real Oban.

  The historical bug this guards against (documented in `demos/README.md`):
  `on_error` used to be forbidden by the generated policies on any
  authorizer-bearing resource, because its action lived outside the bypass and
  default-allow scopes. `on_success` doesn't generate a separate action per
  target — routing happens inside the step's own action via
  `AshWorkflow.Changes.ConditionalOnSuccess` — so there is no analogous
  per-target action to leave uncovered. This test proves that holds: both the
  happy target and the "rejection" target are reachable via a real,
  actor-less Oban run, even with an authorizer and an unrelated step policy on
  the resource.

      screening ──(run_screening, score >= 5)──▶ interview  (policy: interviewer only, past this point)
                └─(run_screening, score < 5)───▶ rejected_by_hr
                └─(run_screening, error)────────▶ screening_failed
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "authorized_screening_workflows"
    repo(AshWorkflowTest.Repo)
  end

  workflow do
    step :screening do
      action :run_screening

      on_success :interview, when: expr(screen_score >= 5)
      on_success :rejected_by_hr, when: expr(screen_score < 5)

      on_error :screening_failed
    end

    step :interview do
      policy actor_attribute_equals(:role, :interviewer)

      transition :schedule, to: :scheduled
    end

    step :scheduled, terminal: true
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
