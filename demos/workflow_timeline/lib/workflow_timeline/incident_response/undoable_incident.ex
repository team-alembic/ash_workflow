defmodule WorkflowTimeline.IncidentResponse.UndoableIncident do
  @moduledoc """
  The same incident workflow as `Incident`, with every manual transition
  marked `undoable?: true`.

  Deliberately a near-copy rather than a shared module: the undo page exists
  to be put side by side with the timeline page, and the only difference
  worth seeing is the `undo` block and the three `undoable?: true` flags.

  Two things it is arranged to demonstrate:

  - **`:resolve` is shared** between `:investigating` and `:escalated`, so it
    merges into one action with two undoable edges. Undo rewinds to whichever
    state the log says it actually came from.
  - **`:triaging` is automatic.** Its transition into `:investigating` is not
    an undoable transition and never can be, so the undo button goes dead the
    moment the triage bot runs — which is the honest answer once the action
    has already had its effects.
  """

  use Ash.Resource,
    domain: WorkflowTimeline.IncidentResponse,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "undoable_incidents"
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

    transition_log WorkflowTimeline.IncidentResponse.UndoableIncidentTransition do
      belongs_to_actor :responder, WorkflowTimeline.IncidentResponse.Responder
    end

    undo do
      within({1, :hours})
    end

    step :triaging do
      action :classify_severity
      on_success :investigating
      on_error :triage_failed
    end

    step :investigating do
      transition :escalate, to: :escalated, undoable?: true
      transition :resolve, to: :resolved, undoable?: true

      timeout :status_reminder, after: {90, :seconds}, action: :send_status_update, repeat: true
      timeout :auto_escalate, after: {8, :minutes}, transition_to: :escalated
    end

    step :escalated do
      transition :resolve, to: :resolved, undoable?: true
    end

    step :resolved, terminal: true
    step :triage_failed, terminal: true
  end
end
