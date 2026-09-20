defmodule WorkflowTimeline.IncidentResponse.IncidentTransition do
  @moduledoc """
  The transition log for `WorkflowTimeline.IncidentResponse.Incident`.

  One row per workflow event — including same-state rows where `from_state ==
  to_state`, written by the recurring `:status_reminder` every. This is the
  resource the timeline UI reads to draw each incident's band.

  Hand-written to satisfy `AshWorkflow.Verifiers.ValidateTransitionLog`
  (required attributes, plus a `belongs_to` back to `Incident` and a matching
  relationship for the `belongs_to_actor :responder` configured there) — the
  generator that scaffolds this file is still in development, so this mirrors
  what it is expected to produce.

  `:backdate` exists only for `priv/repo/seeds.exs`: `AshWorkflow.Changes.RecordEvent`
  always stamps `occurred_at` with `DateTime.utc_now/0`, so seeding a
  timeline that already spans days means writing real rows first and then
  moving their timestamps into the past.
  """

  use Ash.Resource,
    domain: WorkflowTimeline.IncidentResponse,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "incident_transitions"
    repo WorkflowTimeline.Repo

    custom_indexes do
      index [:incident_id, :occurred_at]
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
    belongs_to :incident, WorkflowTimeline.IncidentResponse.Incident,
      allow_nil?: false,
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
        :incident_id,
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
