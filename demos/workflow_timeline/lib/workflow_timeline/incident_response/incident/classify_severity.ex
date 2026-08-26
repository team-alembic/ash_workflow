defmodule WorkflowTimeline.IncidentResponse.Incident.ClassifySeverity do
  @moduledoc """
  The `:triaging` step's automatic action. Simulates an on-call triage bot
  assigning a severity. Sleeps briefly unless `:fast_tests` is set, mirroring
  the `ats` demo's `FakeScore`.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    sleep_ms =
      if Application.get_env(:workflow_timeline, :fast_tests, false),
        do: 10,
        else: Enum.random(500..1_500)

    :timer.sleep(sleep_ms)

    severity = Enum.random([:low, :medium, :high, :critical])

    Ash.Changeset.force_change_attribute(changeset, :severity, severity)
  end
end
