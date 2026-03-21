defmodule AshWorkflowTest.LinearWorkflow do
  @moduledoc """
  Simplest possible workflow: two automatic steps chaining via on_success.

  start → process → complete
                └─(error)─→ failed
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step :process, action: :do_processing, on_success: :complete, on_error: :failed
    step :complete, terminal: true
    step :failed, terminal: true
  end

  actions do
    update :do_processing do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
