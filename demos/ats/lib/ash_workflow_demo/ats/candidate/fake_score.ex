defmodule AshWorkflowDemo.ATS.Candidate.FakeScore do
  @moduledoc """
  Simulates an AI resume scorer. Sleeps 2–5 seconds, assigns a random score
  from 1–10, and picks a canned reason keyed to the score band.
  """

  use Ash.Resource.Change

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
    sleep_ms =
      if Application.get_env(:ash_workflow_demo, :fast_tests, false),
        do: 10,
        else: Enum.random(2_000..5_000)

    :timer.sleep(sleep_ms)
    score = Enum.random(1..10)
    reason = reason_for(score)

    changeset
    |> Ash.Changeset.force_change_attribute(:score, score)
    |> Ash.Changeset.force_change_attribute(:score_reason, reason)
  end

  defp reason_for(score) when score >= 8, do: Enum.random(@high_reasons)
  defp reason_for(score) when score >= 4, do: Enum.random(@mid_reasons)
  defp reason_for(_), do: Enum.random(@low_reasons)
end
