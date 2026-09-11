defmodule AshWorkflowTest.PreciseTimeoutWorkflow do
  @moduledoc """
  A sub-minute deadline under `AshWorkflow.Scheduler.Precise`.

  The same timeout is a compile error under the default scheduler, because cron
  cannot poll for it. This resource is what proves the precision floor comes
  from the selected scheduler rather than being fixed at one minute, and that
  a workflow selecting `Precise` needs no `self_scheduled?` flag and no AshOban
  extension.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    scheduler AshWorkflow.Scheduler.Precise

    step :waiting do
      transition :resolve, to: :done

      timeout :nudge, fire_after: {5, :seconds}, transition_to: :escalated
    end

    step :done, terminal: true
    step :escalated, terminal: true
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
