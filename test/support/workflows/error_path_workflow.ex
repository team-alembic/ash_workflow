defmodule AshWorkflowTest.ErrorPathWorkflow do
  @moduledoc """
  Workflow for testing the on_error transition path.

  start → process ──(success)──→ done
                  └──(error)───→ failed
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step :process, action: :do_processing, on_success: :done, on_error: :failed
    step :done, terminal: true
    step :failed, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title, :should_fail]
    end

    update :do_processing do
      accept []
      change AshWorkflowTest.Changes.MaybeFailChange
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :should_fail, :boolean, default: false, public?: true
  end
end
