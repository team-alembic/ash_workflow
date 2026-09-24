defmodule AshWorkflowTest.OwnTransitionsWorkflow do
  @moduledoc """
  Defines its own private `:transitions` relationship, which
  `AshWorkflow.Transformers.AddRelationships` must keep.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    transition_log AshWorkflowTest.OwnTransitionsLog

    step :waiting do
      transition :resolve, to: :done
    end

    step :done, terminal: true
  end

  attributes do
    uuid_v7_primary_key :id
  end

  relationships do
    has_many :transitions, AshWorkflowTest.OwnTransitionsLog, destination_attribute: :workflow_id
  end
end
