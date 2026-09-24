defmodule AshWorkflowTest.OwnTransitionsLog do
  @moduledoc """
  The transition log for `AshWorkflowTest.OwnTransitionsWorkflow`.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :create]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :from_state, :atom, public?: true
    attribute :to_state, :atom, allow_nil?: false, public?: true
    attribute :transition_name, :atom, allow_nil?: false, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :triggered_by, :atom, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :workflow, AshWorkflowTest.OwnTransitionsWorkflow, allow_nil?: false, public?: true
  end
end
