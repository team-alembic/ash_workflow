defmodule WorkflowTimeline.IncidentResponse.Responder do
  @moduledoc """
  An on-call responder. Configured as the `belongs_to_actor` on
  `IncidentTransition`, so every log row records who (if anyone) caused it.
  """

  use Ash.Resource,
    domain: WorkflowTimeline.IncidentResponse,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "responders"
    repo WorkflowTimeline.Repo
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :team, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:name, :team]
    end
  end
end
