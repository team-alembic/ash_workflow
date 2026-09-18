defmodule AshWorkflowDemo.ATS.Candidate.BureauReturnsResult do
  @moduledoc """
  The bureau answering on its own, when nobody worked the portal in time.

  Most checks come back with something on them. That is a claim about this
  demo rather than about the world: a clear result is a card with nothing to
  read on it, and the disclosure is the joke.

  Only runs on the timeout path. A result returned through the portal moves
  the candidate out of `:background_check` before this step is ever reached.
  """

  use Ash.Resource.Change

  alias AshWorkflowDemo.ATS.Candidate.DbsOffences

  @disclosure_rate 0.6

  @impl true
  def change(changeset, _opts, _context) do
    if is_nil(Ash.Changeset.get_attribute(changeset, :dbs_offence)) and discloses?() do
      Ash.Changeset.force_change_attribute(changeset, :dbs_offence, DbsOffences.random())
    else
      changeset
    end
  end

  defp discloses?, do: :rand.uniform() < @disclosure_rate
end
