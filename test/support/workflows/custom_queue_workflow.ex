defmodule AshWorkflowTest.CustomQueueWorkflow do
  @moduledoc """
  Workflow with a custom Oban queue.

  process → review ──(approve)──→ done
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    queue :hiring_pipeline

    step :process, action: :do_processing, on_success: :review

    step :review do
      manual true
      transition :approve, to: :done

      timeout :reminder, after: {2, :days}, action: :send_reminder
    end

    step :done, terminal: true
  end

  actions do
    update :do_processing do
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
