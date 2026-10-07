defmodule AshWorkflowDemo.ATS.Candidate.SetResponseDelays do
  @moduledoc """
  Sets up the two reviewer clocks and the bureau's flakiness, once, on
  submission.

  Janine answers within seven seconds, drawn from `@hr_range`. Steve's delay
  is drawn from `@lead_range`. Drawing both per candidate is what lets a
  whole room apply at the same moment and still come back staggered across
  the board.

  Janine's deadline is stamped here, because submission is when the candidate
  reaches her. Steve's is stamped later by
  `AshWorkflowDemo.ATS.Candidate.StartLeadClock`, so however long the bureau
  takes does not eat into his time.

  Also draws whether the bureau's own reply on this candidate is flaky. See
  `AshWorkflowDemo.ATS.Candidate.BureauReturnsResult`.
  """

  use Ash.Resource.Change

  @hr_range 1..7
  @lead_range 4..10
  @bureau_flaky_rate 0.5

  @doc "The longest Janine can take to answer, in seconds."
  @spec hr_max_seconds() :: pos_integer()
  def hr_max_seconds, do: @hr_range.last

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
    |> Ash.Changeset.force_change_attribute(:bureau_flaky?, flaky?())
  end

  defp draw(range), do: if(fast_tests?(), do: 0, else: Enum.random(range))

  defp flaky?, do: not fast_tests?() and :rand.uniform() < @bureau_flaky_rate

  defp fast_tests?, do: Application.get_env(:ash_workflow_demo, :fast_tests, false)
end
