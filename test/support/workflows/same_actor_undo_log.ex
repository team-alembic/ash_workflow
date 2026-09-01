defmodule AshWorkflowTest.SameActorUndoLog do
  @moduledoc """
  The transition log for `AshWorkflowTest.SameActorUndoWorkflow`.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read]

    create :create do
      accept [
        :workflow_id,
        :undoes_id,
        :user_id,
        :from_state,
        :to_state,
        :transition_name,
        :occurred_at,
        :triggered_by
      ]
    end

    update :update do
      accept [:occurred_at]
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
    belongs_to :workflow, AshWorkflowTest.SameActorUndoWorkflow,
      allow_nil?: false,
      public?: true,
      attribute_public?: true,
      attribute_writable?: true

    belongs_to :undoes, __MODULE__,
      allow_nil?: true,
      public?: true,
      attribute_public?: true,
      attribute_writable?: true

    belongs_to :user, AshWorkflowTest.Reviewer,
      allow_nil?: true,
      public?: true,
      attribute_public?: true,
      attribute_writable?: true
  end
end
