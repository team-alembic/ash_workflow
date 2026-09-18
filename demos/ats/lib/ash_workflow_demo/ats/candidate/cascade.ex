defmodule AshWorkflowDemo.ATS.Candidate.Cascade do
  @moduledoc """
  After El Jefe makes the offer, rejects every other candidate still moving.

  One slot. The sweep fires the instant the offer is made, across every step
  of the pipeline at once, which is the part that is hard to write by hand and
  trivial to express when the states are declared.
  """

  use Ash.Resource.Change

  require Ash.Query

  # Only the steps a card can actually rest in. The two decision steps resolve
  # within the same call that enters them, so nothing is ever sitting there to
  # sweep.
  @in_flight [:hr_screen, :background_check, :lead_interview, :final_approval]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, hired ->
      %{results: others} =
        AshWorkflowDemo.ATS.Candidate
        |> Ash.Query.filter(state in ^@in_flight and id != ^hired.id)
        |> Ash.read!(authorize?: false)

      Enum.each(others, &AshWorkflowDemo.ATS.slot_taken!(&1, %{}, authorize?: false))

      {:ok, hired}
    end)
  end
end
