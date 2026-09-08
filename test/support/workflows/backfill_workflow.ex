defmodule AshWorkflowTest.BackfillWorkflow do
  @moduledoc """
  Minimal workflow used only by the `ash_workflow.backfill_transition_log`
  task tests.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    transition_log AshWorkflowTest.BackfillTransition

    step :intake do
      transition :advance, to: :done
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
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
