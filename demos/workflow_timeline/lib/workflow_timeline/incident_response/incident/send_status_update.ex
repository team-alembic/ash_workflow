defmodule WorkflowTimeline.IncidentResponse.Incident.SendStatusUpdate do
  @moduledoc """
  The `:status_reminder` every's action. Fires repeatedly while an incident
  sits in `:investigating`, so it never changes state — it just counts how
  many reminders have gone out. `AshWorkflow.Changes.RecordEvent` still
  appends a `from_state == to_state` row for every firing.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    current = Ash.Changeset.get_attribute(changeset, :status_updates_sent) || 0
    Ash.Changeset.force_change_attribute(changeset, :status_updates_sent, current + 1)
  end
end
