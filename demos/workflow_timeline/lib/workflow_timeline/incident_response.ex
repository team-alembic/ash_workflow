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

    resource WorkflowTimeline.IncidentResponse.IncidentTransition
    resource WorkflowTimeline.IncidentResponse.Responder
  end
end
