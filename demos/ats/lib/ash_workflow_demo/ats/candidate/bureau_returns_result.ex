defmodule AshWorkflowDemo.ATS.Candidate.BureauReturnsResult do
  @moduledoc """
  The bureau answering on its own, when nobody worked the portal in time.

  Most checks come back with something on them. That is a claim about this
  demo rather than about the world: a clear result is a card with nothing to
  read on it, and the disclosure is the joke.

  Only runs on the timeout path. A result returned through the portal moves
  the candidate out of `:background_check` before this step is ever reached.

  The bureau is also the demo's third-party API: the kind that fails once and
  works on the retry, which is what `retry` on `step :bureau_result` exists
  for. `AshWorkflowDemo.ATS.Candidate.SetResponseDelays` draws whether a
  candidate is flaky, and a flaky candidate's first attempt here raises
  `BureauUnavailableError` rather than rolling the result. The failure is
  scripted rather than random so the stage behaviour is bounded: a flaky
  candidate fails exactly once, waits out the retry's backoff, and succeeds on
  the second attempt.
  """

  use Ash.Resource.Change

  alias AshWorkflowDemo.ATS.Candidate.DbsOffences

  defmodule BureauUnavailableError do
    defexception message: "the bureau's API did not respond"
  end

  @disclosure_rate 0.6

  @impl true
  def change(changeset, _opts, _context) do
    record = changeset.data
    attempt = (record.bureau_attempts || 0) + 1

    # A raise below aborts this changeset before Ash.update/2 is ever reached,
    # so nothing on it would persist. The attempt counter is bumped through
    # its own action instead: it has to survive the failure it is counting.
    record =
      Ash.update!(record, %{bureau_attempts: attempt},
        action: :bump_bureau_attempts,
        authorize?: false
      )

    if record.bureau_flaky? and attempt == 1 do
      raise BureauUnavailableError
    end

    changeset = Ash.Changeset.force_change_attribute(changeset, :bureau_attempts, attempt)

    if is_nil(Ash.Changeset.get_attribute(changeset, :dbs_offence)) and discloses?() do
      Ash.Changeset.force_change_attribute(changeset, :dbs_offence, DbsOffences.random())
    else
      changeset
    end
  end

  defp discloses?, do: :rand.uniform() < @disclosure_rate
end
