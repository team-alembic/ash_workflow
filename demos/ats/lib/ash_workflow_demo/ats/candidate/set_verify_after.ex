defmodule AshWorkflowDemo.ATS.Candidate.SetVerifyAfter do
  @moduledoc """
  Picks the moment the scorer may collect this candidate: a few seconds out,
  so the `:submitted` step is visible on the projector.

  The randomness is per candidate, which is the point on stage — a batch of
  applicants fans out across the column instead of moving in lockstep.
  """

  use Ash.Resource.Change

  @delay_range 2_000..5_000

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.force_change_attribute(changeset, :verify_after, verify_after())
  end

  defp verify_after do
    delay = if fast_tests?(), do: 0, else: Enum.random(@delay_range)

    DateTime.add(DateTime.utc_now(), delay, :millisecond)
  end

  defp fast_tests?, do: Application.get_env(:ash_workflow_demo, :fast_tests, false)
end
