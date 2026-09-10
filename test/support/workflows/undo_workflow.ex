defmodule AshWorkflowTest.UndoWorkflow do
  @moduledoc """
  Exercises undo: a simple undoable transition, a conditional undoable
  transition with two routes, a transition left undoable-by-omission, and an
  automatic step whose logged event must never be undoable.

  review ──(approve, undoable)──→ publish ──(automatic)──→ done
        ├─(escalate)───────────→ rejected
        └─(defer, undoable)────→ deferred ──(resume, undoable, conditional)──→ review | publish

  `deferred` carries a repeating timeout so its same-state log rows are in the
  way of anything walking the log back to the last real state change.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    transition_log AshWorkflowTest.UndoLog do
      belongs_to_actor :user, AshWorkflowTest.Reviewer
    end

    undo do
      within {1, :hours}
    end

    step :review do
      transition :approve, to: :publish, undoable?: true
      transition :defer, to: :deferred, undoable?: true
      transition :escalate, to: :rejected
    end

    step :publish, action: :run_publish, on_success: :done

    step :deferred do
      transition :resume do
        undoable? true
        route :review, when: expr(priority == :normal)
        route :publish, when: expr(priority == :high)
      end

      timeout :nudge, after: {2, :days}, action: :send_nudge, repeat: true
    end

    step :done, terminal: true
    step :rejected, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title, :priority]
    end

    update :run_publish do
      accept []
    end

    update :send_nudge do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :priority, :atom, default: :normal, public?: true
  end
end
