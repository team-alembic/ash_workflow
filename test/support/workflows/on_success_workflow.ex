defmodule AshWorkflowTest.OnSuccessWorkflow do
  @moduledoc """
  Automatic step with conditional `on_success` entries: an AI screening step
  fans out to `interview` or `rejected_by_hr` based on a score the step's own
  action computes.

  start → screening ──(run_screening, score >= 5)──▶ interview
                     └─(run_screening, score < 5)───▶ rejected_by_hr
                     └─(run_screening, error)────────▶ screening_failed
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step :screening do
      action :run_screening

      on_success :interview, when: expr(screen_score >= 5)
      on_success :rejected_by_hr, when: expr(screen_score < 5)
      # Overlaps with :interview's condition (score 8 satisfies both) — kept
      # last to prove first-match-wins ordering: a "strong" screen should
      # never land here.
      on_success :also_qualifies, when: expr(screen_score >= 0)

      on_error :screening_failed
    end

    step :interview, terminal: true
    step :rejected_by_hr, terminal: true
    step :also_qualifies, terminal: true
    step :screening_failed, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title, :should_fail]
    end

    update :run_screening do
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        cond do
          Ash.Changeset.get_attribute(changeset, :should_fail) ->
            Ash.Changeset.add_error(changeset, field: :title, message: "screening failed")

          Ash.Changeset.get_attribute(changeset, :title) == "strong" ->
            Ash.Changeset.change_attribute(changeset, :screen_score, 8)

          Ash.Changeset.get_attribute(changeset, :title) == "weak" ->
            Ash.Changeset.change_attribute(changeset, :screen_score, 2)

          Ash.Changeset.get_attribute(changeset, :title) == "boundary" ->
            # Exactly the boundary between the two conditions below — proves
            # `>= 5` (not `> 5`) is what was intended: a score of exactly 5
            # should route to :interview, not :rejected_by_hr.
            Ash.Changeset.change_attribute(changeset, :screen_score, 5)

          true ->
            # No route matches a nil score — used to exercise the
            # no-matching-route runtime error.
            changeset
        end
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :should_fail, :boolean, allow_nil?: false, default: false, public?: true
    attribute :screen_score, :integer, public?: true
  end
end
