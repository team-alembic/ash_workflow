defmodule AshWorkflowDemo.ATS.Candidate.FakeScore do
  @moduledoc """
  Simulates an AI resume scorer: assigns a random score from 1–10 and picks a
  canned reason keyed to the score band.

  Deliberately does no waiting. The delay the audience sees belongs to the
  `:submitted` step's `:verify_after` timeout — sleeping here would hold a
  database connection for the duration, and the Oban workflow queue is as wide
  as the connection pool.
  """

  use Ash.Resource.Change

  defmodule UnscorablePitchError do
    defexception message: "the pitch could not be scored"
  end

  @high_reasons [
    "Strong signal across the board.",
    "Pitch hits every note.",
    "Obvious yes — escalate.",
    "Confidence: high. Signal: sharp."
  ]

  @mid_reasons [
    "Fine. Room to grow.",
    "Passes the bar. Barely.",
    "Mid-tier, but has hustle.",
    "Could go either way."
  ]

  @low_reasons [
    "Pitch is thin. Move on.",
    "Did not engage with the prompt.",
    "Better fit elsewhere.",
    "Low signal — not this one."
  ]

  @impl true
  def change(changeset, _opts, _context) do
    pitch = Ash.Changeset.get_attribute(changeset, :pitch)

    unless scorable?(pitch) do
      raise UnscorablePitchError, "no words to score in #{inspect(pitch)}"
    end

    score = Enum.random(1..10)
    reason = reason_for(score)

    changeset
    |> Ash.Changeset.force_change_attribute(:score, score)
    |> Ash.Changeset.force_change_attribute(:score_reason, reason)
  end

  # Gives the :verification_failed route something to be reached by: a pitch
  # with no letters in it is one the scorer cannot say anything about. On stage
  # this is how you demo the on_error branch on purpose.
  defp scorable?(pitch), do: String.match?(pitch, ~r/\p{L}/u)

  defp reason_for(score) when score >= 8, do: Enum.random(@high_reasons)
  defp reason_for(score) when score >= 4, do: Enum.random(@mid_reasons)
  defp reason_for(_), do: Enum.random(@low_reasons)
end
