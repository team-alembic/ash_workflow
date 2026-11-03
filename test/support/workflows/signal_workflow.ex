defmodule AshWorkflowTest.SignalWorkflow do
  @moduledoc """
  A workflow that declares `emit` at every level: the workflow, a step's
  entry and exit, a transition, a transition timeout, an action timeout and an
  `every`. Signals come from `AshWorkflowTest.Signals`.

      review ──(approve)──▶ screening ──(screen)──▶ done
             ├─(reject)──▶ rejected
             ├─ after 2 days ──▶ escalated
             ├─ after 1 day ──▶ (send_reminder)
             └─ every hour ──▶ (send_nudge)
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    scheduler AshWorkflow.Scheduler.Precise
    signals AshWorkflowTest.Signals

    emit :state_changed

    step :review do
      emit :review_started, fields: [:name]
      emit :review_finished, on: :exit

      transition :approve do
        to :screening
        emit :approved, fields: [:name], values: [verdict: "approved"]
      end

      transition :reject, to: :rejected

      timeout :escalate do
        fire_after {2, :days}
        transition_to :escalated
        emit :escalated
      end

      timeout :remind do
        fire_after {1, :days}
        action :send_reminder
        emit :reminded
      end

      every :nudge do
        interval {1, :hours}
        action :send_nudge
        emit :nudged
      end
    end

    step :screening do
      action :screen
      on_success :done
    end

    step :done, terminal: true
    step :rejected, terminal: true
    step :escalated, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:name]
    end

    update :screen do
      accept []
    end

    update :send_reminder do
      accept []
    end

    update :send_nudge do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end
end
