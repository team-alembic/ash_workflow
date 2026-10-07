defmodule AshWorkflowDemo.ATS.Candidate.JanineScreens do
  @moduledoc """
  Janine in HR, reading the pitch and scoring it out of ten.

  Also stamps the reference the bureau will quote back, because the step after
  this one is the background check and the candidate's id would not do: the
  point of that step is that the key correlating the reply is not the primary
  key.

  Does no waiting. The delay the audience sees belongs to the `:hr_screen`
  step's deadline — sleeping here would hold a database connection for the
  duration, and the Oban workflow queue is only as wide as the connection pool.
  """

  use Ash.Resource.Change

  alias AshWorkflowDemo.ATS.DbsBureau

  defmodule UnscorablePitchError do
    defexception message: "the pitch could not be read"
  end

  @strong [
    "Huge culture add. I have already told three people about them.",
    "Genuinely excited. Have asked them to keep Thursday free.",
    "Strong yes. I want this one moved through before Finance notices the band.",
    "Ticks every box on the scorecard, including the ones I added afterwards.",
    "Best pitch in the batch. I have screenshotted it for the all-hands.",
    "They used the word \"stakeholder\" correctly. Unprompted.",
    "I have already ordered their lanyard.",
    "Read it aloud to the team. Someone clapped. It was me.",
    "This pitch has more structure than our org chart.",
    "Would hire twice if headcount allowed. I have asked.",
    "Their cover letter had a narrative arc. I cried at the second act.",
    "Cancelled my other screens. We have found them.",
    "Mentioned documentation without being asked. Fast-tracking.",
    "I would follow this person into a reorg.",
    "Strong communicator. Used paragraphs. Plural.",
    "Pitch was under 200 words. A gift. A genuine gift.",
    "Spelled the company name right. Top five percent already.",
    "Already drafting the welcome Slack message with three emojis.",
    "Exceeds expectations, and I set them after a very good coffee.",
    "Culture fit so strong they may have written our values page."
  ]

  @passable [
    "Solid. Not a culture add, but definitely not a culture subtract.",
    "Fine. Putting them through because the req has been open for nine weeks.",
    "Meets the bar. The bar has been lowered twice, but it meets it.",
    "No concerns. No excitement either. Moving to checks.",
    "Would be a great fit for a role we do not currently have open.",
    "Scoring this in the middle so it does not get flagged in the pipeline review.",
    "Perfectly adequate. I would trust them with a stapler.",
    "They will be fine. Most people are fine. It is fine.",
    "Good energy. Unclear what the energy is for.",
    "Pitch read like a LinkedIn post, but one of the better ones.",
    "Hit every keyword. Possibly by pasting the job ad back to us.",
    "Passes. Mostly because it is Friday and I am tired.",
    "Lukewarm. Like the office coffee, but with potential.",
    "Answered the question. A different question would have been more fun.",
    "Would not stop a meeting for them. Would not leave one either.",
    "Fine. Some notes on font choice, but fine.",
    "Moving forward. The vibes are not bad, they are just vibes.",
    "Credible. Unremarkable. Exactly what the template asked for.",
    "Meets requirements. Exceeds none. Respects all of them.",
    "I have seen better. I have also seen Gary's, so this is fine."
  ]

  @weak [
    "Did not engage with the prompt. Or, arguably, with language.",
    "Says they are a rockstar. We retired that word for a reason.",
    "Pitch is one sentence and two of the words are \"synergy\".",
    "Not a fit. I would rather reopen the req than explain this one.",
    "Asked about the salary band in the pitch. Bold. No.",
    "I have read this four times and I still could not tell you what they do.",
    "Opened with \"To whom it may concern\". It does not concern me.",
    "Listed Microsoft Word as a core competency. In 2026.",
    "Pitch was a link to a Notion page. The Notion page was private.",
    "Described themselves as a \"10x engineer\". Ten times what, they did not say.",
    "Addressed it to a different company. Twice.",
    "Used Comic Sans. In plain text. I do not know how.",
    "Pitched in the third person. Called themselves \"the talent\".",
    "Mentioned their crypto portfolio. Unsolicited. At length.",
    "I asked for a pitch and received a manifesto.",
    "Said they thrive in chaos. We are trying to have less of it.",
    "Included a headshot. Of their dog. The dog is overqualified.",
    "Wrote \"passionate\" eleven times. I counted. I had time.",
    "Ended with \"Thoughts?\" I have several. None for HR records.",
    "Pitch was generated. The prompt was left in."
  ]

  @impl true
  def change(changeset, _opts, _context) do
    pitch = Ash.Changeset.get_attribute(changeset, :pitch)

    unless readable?(pitch) do
      raise UnscorablePitchError, "no words to read in #{inspect(pitch)}"
    end

    score = Enum.random(1..10)

    changeset
    |> Ash.Changeset.force_change_attribute(:score, score)
    |> Ash.Changeset.force_change_attribute(:score_reason, reason_for(score))
    |> Ash.Changeset.force_change_attribute(:dbs_reference, DbsBureau.generate_reference())
  end

  # Gives the :on_error route something to be reached by: a pitch with no
  # letters in it is one Janine cannot say anything about. On stage this is how
  # you demo the error branch on purpose.
  defp readable?(pitch), do: String.match?(pitch, ~r/\p{L}/u)

  defp reason_for(score) when score >= 8, do: Enum.random(@strong)
  defp reason_for(score) when score >= 4, do: Enum.random(@passable)
  defp reason_for(_), do: Enum.random(@weak)
end
