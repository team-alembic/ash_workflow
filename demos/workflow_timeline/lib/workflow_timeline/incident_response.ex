defmodule WorkflowTimeline.IncidentResponse do
  @moduledoc """
  The incident-response domain — the workflow this demo puts on a timeline.
  """

  use Ash.Domain

  resources do
    resource WorkflowTimeline.IncidentResponse.Incident do
      define :report, action: :report, args: [:title, :description]
      define :escalate, action: :escalate
      define :resolve, action: :resolve
      define :classify_severity, action: :classify_severity
      define :send_status_update, action: :send_status_update
      define :list_incidents, action: :read
      define :get_incident, action: :read, get_by: :id
    end

    resource WorkflowTimeline.IncidentResponse.UndoableIncident do
      define :report_undoable, action: :report, args: [:title, :description]
      define :escalate_undoable, action: :escalate
      define :resolve_undoable, action: :resolve
      define :undo_incident, action: :undo
      define :classify_severity_undoable, action: :classify_severity
      define :list_undoable_incidents, action: :read
    end

    resource WorkflowTimeline.IncidentResponse.IncidentTransition
    resource WorkflowTimeline.IncidentResponse.UndoableIncidentTransition
    resource WorkflowTimeline.IncidentResponse.Responder
  end
end
