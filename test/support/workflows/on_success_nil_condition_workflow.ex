defmodule AshWorkflowTest.OnSuccessNilConditionWorkflow do
  @moduledoc """
  A numeric `on_success` comparison (not `==`, which `OnSuccessFallbackWorkflow`
  already covers) paired with a trailing unconditional fallback, so a `nil`
  attribute exercises the same three-valued-logic path as SQL: `nil >= 5` is
  `nil`, not `false`, but the fallback catches it regardless since it has no
  condition to fail.

  start → grading ──(run_grading, grade_score >= 5)──▶ pass
                   └─(run_grading, fallback)──────────▶ fail
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step :grading do
      action :run_grading

      on_success :pass, when: expr(grade_score >= 5)
      on_success :fail
    end

    step :pass, terminal: true
    step :fail, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title]
    end

    update :run_grading do
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        case Ash.Changeset.get_attribute(changeset, :title) do
          "unscored" -> changeset
          "strong" -> Ash.Changeset.change_attribute(changeset, :grade_score, 8)
          _ -> Ash.Changeset.change_attribute(changeset, :grade_score, 2)
        end
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :grade_score, :integer, public?: true
  end
end
