defmodule DocumentApproval.Document.SendNudge do
  @moduledoc """
  Stands in for emailing the reviewers. Counting the nudges instead of sending
  them is what lets the test assert that a repeating timeout really does fire
  more than once.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.change_attribute(
      changeset,
      :nudges_sent,
      changeset.data.nudges_sent + 1
    )
  end
end
