defmodule AshWorkflowTest.Postgres.StaleTransitionWorkflow do
  @moduledoc """
  Postgres-backed workflow, so the stale-transition refusal can be shown
  against a real filtered `UPDATE`: a conditional `advance`, which updates
  non-atomically, and a static `reject`, which updates atomically.

      screening ──(advance, is_nil(path_type) or path_type == :agency)──▶ interviewing
                ├─(advance, path_type == :family)───────────────────────▶ compliance
                └─(reject)──────────────────────────────────────────────▶ rejected
      interviewing ──(withdraw)──▶ rejected
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Postgres.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "stale_transition_workflows"
    repo(AshWorkflowTest.Repo)
  end

  workflow do
    step :screening do
      transition :advance do
        route :interviewing, when: expr(is_nil(path_type) or path_type == :agency)
        route :compliance, when: expr(path_type == :family)
      end

      transition :reject, to: :rejected
    end

    step :interviewing do
      transition :withdraw, to: :rejected
    end

    step :compliance, terminal: true
    step :rejected, terminal: true
  end

  code_interface do
    define :submit
  end

  actions do
    defaults [:read]

    create :submit do
      accept [:candidate_name, :path_type]
    end

    update :classify do
      accept [:path_type]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :candidate_name, :string, allow_nil?: false, public?: true
    attribute :path_type, :atom, constraints: [one_of: [:agency, :family]], public?: true
  end
end
