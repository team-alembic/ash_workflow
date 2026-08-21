defmodule AshWorkflowDemo.ATS.Candidate.Cascade do
  @moduledoc """
  After a candidate is hired, transitions every other non-terminal candidate
  to :position_filled. The one-slot cascade.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, hired ->
      %{results: others} =
        AshWorkflowDemo.ATS.Candidate
        |> Ash.Query.filter(state in [:verifying, :review] and id != ^hired.id)
        |> Ash.read!(authorize?: false)

      others
      |> Enum.each(fn candidate ->
        AshWorkflowDemo.ATS.position_filled!(candidate, %{}, authorize?: false)
      end)

      {:ok, hired}
    end)
  end
end
