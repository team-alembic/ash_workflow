defmodule AshWorkflowTest.StatusWorkflow do
  @moduledoc """
  A workflow that stores its state in `status` rather than `state`, declared
  through `state_attribute` on the `workflow` section.

  It carries one of everything that has to follow the renamed attribute: an
  automatic step, a manual transition, a conditional transition, a timeout,
  and a transition log.

  intake ──(automatic)──→ review ──(approve)─────────→ published
                                 ├─(triage, routed)──→ published | rejected
                                 └─ 7 days ──────────→ escalated
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    state_attribute :status

    transition_log AshWorkflowTest.StatusLog

    step :intake, action: :process_intake, on_success: :review

    step :review do
      transition :approve, to: :published

      transition :triage do
        route :published, when: expr(priority == :high)
        route :rejected, when: expr(priority == :normal)
      end

      timeout :escalation, after: {7, :days}, transition_to: :escalated
    end

    step :published, terminal: true
    step :rejected, terminal: true
    step :escalated, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title, :priority]
    end

    update :process_intake do
      accept []
    end

    # Lets a test backdate `state_entered_at` without leaving the step.
    update :touch do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :priority, :atom, default: :normal, public?: true
  end
end
