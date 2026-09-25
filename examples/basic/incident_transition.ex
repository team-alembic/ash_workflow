defmodule BasicWorkflow.IncidentTransition do
  @moduledoc """
  The transition log for `BasicWorkflow.Incident`: one row per workflow event.

  The `undoes` relationship points an undo row at the row it reverses, which
  is what the incident's `undo` block needs.
  """

  use Ash.Resource,
    domain: BasicWorkflow.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "incident_transitions"
    repo(Example.Repo)
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
    belongs_to :incident, BasicWorkflow.Incident,
      allow_nil?: false,
      public?: true,
      attribute_writable?: true

    belongs_to :undoes, __MODULE__,
      allow_nil?: true,
      public?: true,
      attribute_writable?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :incident_id,
        :undoes_id,
        :from_state,
        :to_state,
        :transition_name,
        :occurred_at,
        :triggered_by
      ]
    end
  end
end
