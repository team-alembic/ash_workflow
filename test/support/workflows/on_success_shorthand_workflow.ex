defmodule AshWorkflowTest.OnSuccessShorthandWorkflow do
  @moduledoc """
  Exercises the two unconditional forms of `on_success`: the inline keyword
  shorthand (`step :x, action: :y, on_success: :z, on_error: :w`, with no
  `do...end` block at all) and the block form with a bare target and no
  `when` (`on_success :review`). Both build the same unconditional
  `AshWorkflow.Entities.Route` via Spark's single-arg entity shorthand, so
  both should behave identically — a plain `transition_state`, no runtime
  expression evaluation.

  start → tagging ──(run_tagging)──▶ verifying ──(run_verification)──▶ review
                   └─(error)────────▶ tagging_failed
                                    verifying └─(error)───────────────▶ verification_failed
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    # Pure inline shorthand: no do...end block at all.
    step :tagging, action: :run_tagging, on_success: :verifying, on_error: :tagging_failed

    step :verifying do
      action :run_verification
      on_success :review
      on_error :verification_failed
    end

    step :review, terminal: true
    step :tagging_failed, terminal: true
    step :verification_failed, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title, :should_fail]
    end

    update :run_tagging do
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        if Ash.Changeset.get_attribute(changeset, :should_fail) do
          Ash.Changeset.add_error(changeset, field: :title, message: "tagging failed")
        else
          changeset
        end
      end
    end

    update :run_verification do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :should_fail, :boolean, allow_nil?: false, default: false, public?: true
  end
end
