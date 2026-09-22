defmodule AshWorkflowTest.PreciseStatusWorkflow do
  @moduledoc """
  A deadline under `AshWorkflow.Scheduler.Precise` on a workflow that keeps its
  state in `status` rather than `state`.

  `AshWorkflow.Scheduler.Precise.Timeline` rebuilds the step predicate to fold
  the horizon's bound in rather than reusing `AshWorkflow.Scheduler.Work.match`,
  so this resource is what proves the rebuilt filter reads the attribute the
  workflow named.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    state_attribute :status

    scheduler AshWorkflow.Scheduler.Precise

    step :waiting do
      transition :resolve, to: :done

      timeout :nudge, fire_after: {1, :seconds}, field: :deadline_from, transition_to: :escalated
    end

    step :done, terminal: true
    step :escalated, terminal: true
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:title, :deadline_from]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :deadline_from, :utc_datetime_usec, public?: true
  end
end
