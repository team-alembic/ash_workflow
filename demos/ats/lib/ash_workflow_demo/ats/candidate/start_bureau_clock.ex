defmodule AshWorkflowDemo.ATS.Candidate.StartBureauClock do
  @moduledoc """
  Sets the moment the bureau's own timeout fires, on the way into
  `:background_check`.

  Runs straight after `AshWorkflowDemo.ATS.Candidate.JanineScreens` on
  `:record_hr_screen`, so the window is armed before the candidate ever enters
  the step it governs. Random rather than fixed, and short enough that the
  audience sees it lapse without a script needing to run the portal.
  """

  use Ash.Resource.Change

  @range 8..20

  @impl true
  def change(changeset, _opts, _context) do
    delay = if(fast_tests?(), do: 0, else: Enum.random(@range))

    Ash.Changeset.force_change_attribute(
      changeset,
      :dbs_respond_after,
      DateTime.add(DateTime.utc_now(), delay, :second)
    )
  end

  defp fast_tests?, do: Application.get_env(:ash_workflow_demo, :fast_tests, false)
end
