defmodule AshWorkflowTest.PreciseRetryWorkflow do
  @moduledoc """
  An automatic step under `AshWorkflow.Scheduler.Precise` whose action always
  fails, with a `retry` block declaring two attempts and a one-second
  backoff.

  Used to prove `AshWorkflow.Scheduler.Precise.Timeline` re-arms a timer for
  the backoff delay after a failed attempt instead of running `on_error`
  immediately, and only reaches `on_error` once the final attempt has also
  failed.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    scheduler AshWorkflow.Scheduler.Precise

    step :processing do
      action :process
      on_success :done
      on_error :failed

      retry do
        max_attempts 2
        backoff {1, :seconds}
      end
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

    update :process do
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        Ash.Changeset.add_error(changeset, "always fails")
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
