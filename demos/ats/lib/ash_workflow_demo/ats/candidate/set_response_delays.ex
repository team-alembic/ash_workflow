defmodule AshWorkflowDemo.ATS.Candidate.SetResponseDelays do
  @moduledoc """
  Draws how long Janine and Steve each take on this candidate, once, on
  submission.

  The delays are data on the record rather than a sleep inside either
  reviewer, which is what lets a whole room apply at the same moment and still
  fan out across the board.

  Janine's deadline is stamped here, because submission is when the candidate
  reaches her. Steve's is stamped later by
  `AshWorkflowDemo.ATS.Candidate.StartLeadClock`, so however long the bureau
  takes does not eat into his time.
  """

  use Ash.Resource.Change

  @hr_range 3..8
  @lead_range 4..10

  @impl true
  def change(changeset, _opts, _context) do
    hr_delay = draw(@hr_range)

    changeset
    |> Ash.Changeset.force_change_attribute(:hr_delay_seconds, hr_delay)
    |> Ash.Changeset.force_change_attribute(:lead_delay_seconds, draw(@lead_range))
    |> Ash.Changeset.force_change_attribute(
      :hr_respond_after,
      DateTime.add(DateTime.utc_now(), hr_delay, :second)
    )
  end

  defp draw(range), do: if(fast_tests?(), do: 0, else: Enum.random(range))

  defp fast_tests?, do: Application.get_env(:ash_workflow_demo, :fast_tests, false)
end
