defmodule AshWorkflowTest.BackfillTransition do
  @moduledoc """
  Transition log for `AshWorkflowTest.BackfillWorkflow`, used only by the
  `ash_workflow.backfill_transition_log` task tests. Has a `:destroy` action
  so tests can drop rows to simulate records that predate the log.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :workflow_id,
        :from_state,
        :to_state,
        :transition_name,
        :occurred_at,
        :triggered_by
      ]
    end
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
    belongs_to :workflow, AshWorkflowTest.BackfillWorkflow,
      allow_nil?: false,
      public?: true,
      attribute_public?: true,
      attribute_writable?: true
  end
end
