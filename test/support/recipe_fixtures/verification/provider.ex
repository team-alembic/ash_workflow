defmodule AshWorkflowTest.RecipeFixtures.Verification.Provider do
  @moduledoc """
  Stands in for the provider call an application adds to a generated `:verify`
  action. It answers by the subject's document number.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      %{subject: subject} = Ash.load!(changeset.data, :subject, authorize?: false)
      answer(changeset, subject.number)
    end)
  end

  defp answer(changeset, "genuine"),
    do: Ash.Changeset.force_change_attribute(changeset, :outcome, :passed)

  defp answer(changeset, "forged"),
    do: Ash.Changeset.force_change_attribute(changeset, :outcome, :failed)

  defp answer(changeset, "unreachable"),
    do: Ash.Changeset.add_error(changeset, "provider unreachable")
end
