defmodule AshWorkflowDemo.ATS.Candidate.SteveInterviews do
  @moduledoc """
  Steve, the engineering lead, writing up the interview.

  Steve has read the disclosure. If the bureau found something, his note says
  so, which is how the joke survives past the DBS column and into the record
  El Jefe reads before deciding.
  """

  use Ash.Resource.Change

  @strong [
    "Knows their stuff. Would ship with them on a Friday.",
    "Asked better questions than I did. Slightly threatened. Hire.",
    "Drew the right boxes and then argued with my arrows. Correctly.",
    "Said \"it depends\" and then explained what it depends on. Rare.",
    "Did not once mention microservices. I nearly cried."
  ]

  @passable [
    "Competent. Needs a code review habit and a shorter function.",
    "Got there. Took the scenic route through three design patterns.",
    "Fine. I would pair with them for a month before letting them near billing.",
    "No red flags. No fireworks. A safe pair of hands and a long PR.",
    "Solved it, then explained it using a metaphor about restaurants."
  ]

  @weak [
    "Could not explain their own diagram. The diagram had four boxes.",
    "Argued with the question for twenty minutes and then answered a different one.",
    "Reached for a framework before reading the brief. Then a second framework.",
    "Proposed a rewrite. Of our entire stack. In the interview.",
    "Described their last outage as \"a learning opportunity for the team\"."
  ]

  @unbothered [
    "Saw the disclosure. Honestly, relatable.",
    "HR flagged something. I have done worse before lunch.",
    "Read the file. Frankly we have all been there.",
    "The disclosure came up. We laughed. Then we talked about indexes.",
    "Yes I saw it. It is the least alarming thing in their git history.",
    "Compliance sent me the report. I have framed it."
  ]

  @impl true
  def change(changeset, _opts, _context) do
    score = Enum.random(1..10)
    offence = Ash.Changeset.get_attribute(changeset, :dbs_offence)

    changeset
    |> Ash.Changeset.force_change_attribute(:lead_score, score)
    |> Ash.Changeset.force_change_attribute(:lead_note, note_for(score, offence))
  end

  # A disclosure never sinks a candidate on its own — Steve has opinions about
  # the code, not the criminal record. It only changes what he writes down.
  defp note_for(score, offence) when is_binary(offence) and score >= 4,
    do: Enum.random(@unbothered)

  defp note_for(score, _offence) when score >= 8, do: Enum.random(@strong)
  defp note_for(score, _offence) when score >= 4, do: Enum.random(@passable)
  defp note_for(_score, _offence), do: Enum.random(@weak)
end
