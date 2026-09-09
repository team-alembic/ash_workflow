defmodule AshWorkflowTest.CustomSchedulerWorkflow do
  @moduledoc """
  A workflow whose scheduler is not Oban, and which therefore does not have the
  AshOban extension at all.

  Covers an automatic step with an error path, a transition timeout and an
  action timeout, so the `Work` list has one of each shape.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    scheduler {AshWorkflowTest.TestScheduler, precision: :high}

    step :processing do
      action :process
      on_success :review
      on_error :failed
    end

    step :review do
      transition :approve, to: :approved

      timeout :nudge, after: {2, :days}, action: :send_nudge
      timeout :escalate, after: {7, :days}, transition_to: :escalated
    end

    step :approved, terminal: true
    step :escalated, terminal: true
    step :failed, terminal: true
  end

  actions do
    create :create do
      accept [:title]
    end

    update :process do
      accept []
      require_atomic? false
    end

    update :send_nudge do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
