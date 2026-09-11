defmodule AshWorkflowTest.PreciseDeadlineWorkflow do
  @moduledoc """
  A one-second deadline measured against a field the test writes.

  The field is what makes the timing testable. Setting `deadline_from` to 800
  milliseconds ago puts the deadline 200 milliseconds in the future, so a test
  can watch a timer fire without waiting a second for it, and setting the field
  further back makes the deadline already due.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
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

    update :set_deadline_from do
      accept [:deadline_from]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :deadline_from, :utc_datetime_usec, public?: true
  end
end
