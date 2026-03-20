defmodule AshWorkflowTest.FullPipeline do
  @moduledoc """
  A realistic multi-step pipeline combining automatic steps, manual transitions,
  timeouts, and policies — all in a single resource.

  start → intake ──→ review ──(advance)──→ process ──→ final_review ──(approve)──→ done
                            └─(reject)───→ rejected              └─(reject)───→ rejected
                            └─(hold)─────→ on_hold
                   (2d reminder, 7d escalation)
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshWorkflow]

  workflow do
    step(:intake, action: :run_intake, on_success: :review, on_error: :intake_failed)

    step :review do
      manual true
      policy actor_attribute_equals(:role, :reviewer)

      transition(:advance, to: :process)
      transition(:reject_at_review, to: :rejected)
      transition(:hold, to: :on_hold)

      timeout(:reminder, after: {2, :days}, action: :send_review_reminder)
      timeout(:escalation, after: {7, :days}, transition_to: :escalated)
    end

    step :on_hold do
      manual true
      policy actor_attribute_equals(:role, :reviewer)

      transition(:reactivate, to: :review)
      transition(:reject_on_hold, to: :rejected)
    end

    step(:process, action: :run_processing, on_success: :final_review)

    step :final_review do
      manual true
      policy actor_attribute_equals(:role, :approver)

      transition(:approve, to: :done)
      transition(:reject_at_final, to: :rejected)
    end

    step(:done, terminal: true)
    step(:rejected, terminal: true)
    step(:intake_failed, terminal: true)
    step(:escalated, terminal: true)
  end

  actions do
    update :run_intake do
      accept []
    end

    update :run_processing do
      accept []
    end

    update :send_review_reminder do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :notes, :string, public?: true
  end
end
