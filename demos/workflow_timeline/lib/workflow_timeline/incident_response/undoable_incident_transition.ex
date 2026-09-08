defmodule WorkflowTimeline.IncidentResponse.UndoableIncidentTransition do
  @moduledoc """
  The transition log for `UndoableIncident`.

  Identical to `IncidentTransition` but for the self-referencing `undoes`
  relationship, which is what undo requires and what
  `mix ash_workflow.gen.transition_log` now scaffolds. An undo row points at
  the row it reverses; neither row is ever mutated or deleted, which is what
  lets the undo page draw the same history two ways from one set of rows.
  """

  use Ash.Resource,
    domain: WorkflowTimeline.IncidentResponse,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "undoable_incident_transitions"
    repo WorkflowTimeline.Repo

    custom_indexes do
      index [:undoable_incident_id, :occurred_at]
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
    belongs_to :undoable_incident, WorkflowTimeline.IncidentResponse.UndoableIncident,
      allow_nil?: false,
      public?: true,
      attribute_public?: true,
      attribute_writable?: true

    belongs_to :undoes, __MODULE__,
      allow_nil?: true,
      public?: true,
      attribute_public?: true,
      attribute_writable?: true

    belongs_to :responder, WorkflowTimeline.IncidentResponse.Responder,
      allow_nil?: true,
      public?: true,
      attribute_public?: true,
      attribute_writable?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :undoable_incident_id,
        :undoes_id,
        :responder_id,
        :from_state,
        :to_state,
        :transition_name,
        :occurred_at,
        :triggered_by
      ]
    end

    update :backdate do
      accept [:occurred_at]
      require_atomic? false
    end
  end
end
