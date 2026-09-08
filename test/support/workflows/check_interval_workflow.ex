defmodule AshWorkflowTest.CheckIntervalWorkflow do
  @moduledoc """
  Workflow with a resource-level `check_interval`, one timeout inheriting it and
  one overriding it, so trigger polling can be asserted at both levels.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    check_interval "0 * * * *"

    step :processing do
      action :process
      on_success :waiting
    end

    step :waiting do
      transition :resolve, to: :done

      timeout :inherits, after: {3, :days}, action: :send_reminder

      # Sub-minute deadlines are only legal when something other than cron
      # drives the trigger.
      timeout :self_scheduled,
        after: {5, :seconds},
        action: :send_reminder,
        self_scheduled?: true

      timeout :overrides,
        after: {7, :days},
        transition_to: :escalated,
        check_interval: "0 9 * * *"
    end

    step :done, terminal: true
    step :escalated, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title]
    end

    update :process do
      accept []
    end

    update :send_reminder do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
