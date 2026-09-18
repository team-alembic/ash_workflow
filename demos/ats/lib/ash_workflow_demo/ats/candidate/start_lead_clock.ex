defmodule AshWorkflowDemo.ATS.Candidate.StartLeadClock do
  @moduledoc """
  Sets the moment Steve comes back, on the way into `:lead_interview`.

  Runs on all three routes in: both portal results and the bureau's own.

  The delay was drawn for this candidate on submission. Stamping it here
  rather than at submission means the clock starts when they reach Steve, so
  however long the bureau took does not eat into his time.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    delay = Ash.Changeset.get_attribute(changeset, :lead_delay_seconds) || 0

    Ash.Changeset.force_change_attribute(
      changeset,
      :lead_respond_after,
      DateTime.add(DateTime.utc_now(), delay, :second)
    )
  end
end
