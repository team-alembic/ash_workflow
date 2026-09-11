defmodule AshWorkflowTest.RetryWorkflow do
  @moduledoc """
  Exercises every shape the `retry` block can take: a step that declares none,
  a step with a fixed backoff, a step with the default exponential backoff,
  and a timeout with its own `retry` block. `AshWorkflow.Scheduler.Oban` turns
  each into a generated trigger's `max_attempts` and `backoff`, and
  `AshWorkflow.Info.scheduled_work/1` carries the same policy as an
  `AshWorkflow.Entities.Retry` struct on each `Work`.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :no_retry do
      action :step_a
      on_success :fixed_backoff
      on_error :failed
    end

    step :fixed_backoff do
      action :step_b
      on_success :default_backoff
      on_error :failed

      retry do
        max_attempts 3
        backoff {10, :seconds}
      end
    end

    step :default_backoff do
      action :step_c
      on_success :waiting
      on_error :failed

      retry do
        max_attempts 5
      end
    end

    step :waiting do
      transition :resolve, to: :done

      timeout :nudge,
        after: {2, :days},
        action: :send_nudge,
        do:
          (retry do
             max_attempts 2
             backoff {30, :seconds}
           end)
    end

    step :done, terminal: true
    step :failed, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title]
    end

    update :step_a do
      accept []
    end

    update :step_b do
      accept []
    end

    update :step_c do
      accept []
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
