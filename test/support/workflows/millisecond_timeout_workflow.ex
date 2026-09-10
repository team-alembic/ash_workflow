defmodule AshWorkflowTest.MillisecondTimeoutWorkflow do
  @moduledoc """
  A deadline expressed in milliseconds, which only `AshWorkflow.Scheduler.Precise`
  can honour.

  `AshWorkflowTest.PreciseDeadlineWorkflow` reaches a sub-second deadline by
  measuring a one-second duration against a field the test backdates. This one
  states the sub-second duration directly, so it is what proves the
  `:milliseconds` unit survives the whole path: the entity's validation, the
  generated `match` expression, and `AshWorkflow.Scheduler.due_at/2`.

  The deadline still measures against `deadline_from` so a test can put it
  either side of now without sleeping.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    scheduler AshWorkflow.Scheduler.Precise

    step :waiting do
      transition :resolve, to: :done

      timeout :nudge,
        after: {250, :milliseconds},
        field: :deadline_from,
        transition_to: :escalated
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
