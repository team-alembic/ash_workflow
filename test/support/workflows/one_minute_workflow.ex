defmodule AshWorkflowTest.OneMinuteWorkflow do
  @moduledoc """
  One minute is the shortest deadline a cron scheduler can honour, so it is the
  boundary the precision verifier must allow.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step :waiting do
      transition :resolve, to: :done

      timeout :nudge, after: {1, :minutes}, transition_to: :escalated
    end

    step :done, terminal: true
    step :escalated, terminal: true
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
