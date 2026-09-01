defmodule AshWorkflowTest.LoggedWorkflow do
  @moduledoc """
  Exercises every `triggered_by` value the transition log records: an
  automatic step (`:automatic`/`:error_path`), a manual transition
  (`:manual`), a repeating action timeout (`:timeout`, `from_state ==
  to_state`), and a transitioning timeout (`:timeout`), on top of the
  `:initial` row every workflow gets on create.

  start → intake ──(success)──→ review ──(approve)──→ done
                  └──(error)───→ failed          └─(reject)───→ rejected
                                (2d reminder, repeat; 7d escalation)
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    transition_log AshWorkflowTest.LoggedTransition do
      belongs_to_actor :user, AshWorkflowTest.Reviewer
    end

    step :intake, action: :process_intake, on_success: :review, on_error: :failed

    step :review do
      transition :approve, to: :done
      transition :reject, to: :rejected

      timeout :reminder, after: {2, :days}, action: :send_reminder, repeat: true
      timeout :escalation, after: {7, :days}, transition_to: :escalated
    end

    step :done, terminal: true
    step :rejected, terminal: true
    step :failed, terminal: true
    step :escalated, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title, :should_fail]
    end

    update :process_intake do
      accept []
      change AshWorkflowTest.Changes.MaybeFailChange
    end

    update :send_reminder do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :should_fail, :boolean, default: false, public?: true
  end
end
