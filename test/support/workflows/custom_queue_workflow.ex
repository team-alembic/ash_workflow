defmodule AshWorkflowTest.CustomQueueWorkflow do
  @moduledoc """
  Workflow with a custom Oban queue.

  process → review ──(approve)──→ done
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    queue :hiring_pipeline

    step :process, action: :do_processing, on_success: :review

    step :review do
      transition :approve, to: :done

      timeout :reminder, fire_after: {2, :days}, action: :send_reminder
    end

    step :done, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title]
    end

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
