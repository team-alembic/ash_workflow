defmodule WorkflowTimeline.IncidentResponse.Incident do
  @moduledoc """
  An operational incident moving through triage, investigation, and
  resolution:

      (create) ─▶ triaging ──(auto: classify_severity)──▶ investigating ──(escalate)──▶ escalated ──(resolve)──▶ resolved
                     │                                         │  ▲                          │
                     │                                         │  every 90s: status reminder   │
                     └──(on_error)──▶ triage_failed            │  (repeat, no state change)    │
                                                                └──(resolve)───────────────────▶ resolved
                                                                └──(8 min unresolved)──▶ escalated

  This is the workflow the timeline demo puts on screen. `transition_log`
  is enabled here, so every event above — including the repeating status
  reminder, which does *not* change state — is recorded on
  `IncidentTransition` and readable through `history/1` and `state_at/2`.
  """

  use Ash.Resource,
    domain: WorkflowTimeline.IncidentResponse,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow]

  postgres do
    table "incidents"
    repo WorkflowTimeline.Repo
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :title, :string, allow_nil?: false, public?: true
    attribute :description, :string, allow_nil?: false, public?: true

    attribute :severity, :atom,
      constraints: [one_of: [:low, :medium, :high, :critical]],
      public?: true

    attribute :status_updates_sent, :integer, allow_nil?: false, default: 0, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    create :report do
      accept [:title, :description]
    end

    update :classify_severity do
      accept []
      require_atomic? false
      change WorkflowTimeline.IncidentResponse.Incident.ClassifySeverity
    end

    update :send_status_update do
      accept []
      require_atomic? false
      change WorkflowTimeline.IncidentResponse.Incident.SendStatusUpdate
    end

    update :seed_snapshot do
      accept [:state_entered_at]
      require_atomic? false
    end
  end

  workflow do
    check_interval "*/5 * * * *"

    transition_log WorkflowTimeline.IncidentResponse.IncidentTransition do
      belongs_to_actor :responder, WorkflowTimeline.IncidentResponse.Responder
    end

    step :triaging do
      action :classify_severity
      on_success :investigating
      on_error :triage_failed
    end

    step :investigating do
      transition :escalate, to: :escalated
      transition :resolve, to: :resolved

      timeout :status_reminder, after: {90, :seconds}, action: :send_status_update, repeat: true
      timeout :auto_escalate, after: {8, :minutes}, transition_to: :escalated
    end

    step :escalated do
      transition :resolve, to: :resolved
    end

    step :resolved, terminal: true
    step :triage_failed, terminal: true
  end
end
