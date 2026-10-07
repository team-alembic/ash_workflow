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
    "Did not once mention microservices. I nearly cried.",
    "Deleted more code than they wrote. My kind of person.",
    "Wrote the test first. Did not even make a speech about it.",
    "Found a bug in our interview question. Hire and fix the question.",
    "Read the error message. The whole thing. Out loud.",
    "Knew what the database was doing. Most of us just hope.",
    "Explained a monad without drawing a burrito. Remarkable.",
    "Asked what happens on retry. Correct answer to every question.",
    "Calm under pressure. I turned off the wifi to check.",
    "Named things well. That is half of the job. The other half is cache invalidation.",
    "Would let them near production. Would let them near my production.",
    "Spotted the off-by-one before I finished reading it out.",
    "Their commit messages have verbs. I want to cry again.",
    "Suggested we just use Postgres. Correct.",
    "Could explain their code to me, and to a manager. Different explanations. Both right.",
    "Asked about the on-call rota before the salary. Hire immediately."
  ]

  @passable [
    "Competent. Needs a code review habit and a shorter function.",
    "Got there. Took the scenic route through three design patterns.",
    "Fine. I would pair with them for a month before letting them near billing.",
    "No red flags. No fireworks. A safe pair of hands and a long PR.",
    "Solved it, then explained it using a metaphor about restaurants.",
    "Got the answer. Also got two other answers. Picked one eventually.",
    "Fine. Strong opinions about semicolons that I chose not to explore.",
    "Knows the basics. Knows a few advanced bits. Has guessed the rest convincingly.",
    "Wrote a working solution and seven helper functions it did not need.",
    "Solid, once we agreed that \"temporary\" is not a design pattern.",
    "Average. Which, in this market, is a compliment.",
    "Asked to Google something. Honest. Also slow.",
    "Correct, eventually, after a long detour via Kubernetes.",
    "Good instincts. Bad variable names. Teachable.",
    "Recovered well after confidently mis-naming three HTTP status codes.",
    "Talked through everything. Absolutely everything. Out loud.",
    "Code works. Tests would have been nice. Vibes were immaculate.",
    "Would be great with a mentor. Would be dangerous with admin rights.",
    "Passed, but called YAML a programming language and meant it.",
    "Middle of the pack. The pack is pretty good this year."
  ]

  @weak [
    "Could not explain their own diagram. The diagram had four boxes.",
    "Argued with the question for twenty minutes and then answered a different one.",
    "Reached for a framework before reading the brief. Then a second framework.",
    "Proposed a rewrite. Of our entire stack. In the interview.",
    "Described their last outage as \"a learning opportunity for the team\".",
    "Wrote the solution in a single 300-character line and called it elegant.",
    "Asked if they could use AI. Then asked the AI if they could use AI.",
    "Tried to centre a div. We ran out of time.",
    "Started with \"Well, actually\". Continued with nothing actual.",
    "Said tests are for people who do not trust their code. I do not trust their code.",
    "Put the business logic in the CSS. I did not know you could.",
    "Recommended blockchain. For the login page.",
    "Said Ash was \"basically just Rails\". We have ended the call.",
    "Called the database \"the Excel bit\".",
    "Spent the whole interview tuning their terminal colours.",
    "Answered every question with \"we would put it in a queue\".",
    "Said they do not do code review because their code does not need it.",
    "Muted for the hard question. Unmuted for the easy one.",
    "Wanted to rename our product. Had a logo ready.",
    "Asked if the interview could be async. Then did not reply."
  ]

  @unbothered [
    "Saw the disclosure. Honestly, relatable.",
    "The bureau flagged something. I have done worse before lunch.",
    "Read the file. Frankly we have all been there.",
    "The disclosure came up. We laughed. Then we talked about indexes.",
    "Yes I saw it. It is the least alarming thing in their git history.",
    "Compliance sent me the report. I have framed it.",
    "Saw the record. Asked them about it. Their reasoning was sound, sadly.",
    "The disclosure is honestly the best part of the application.",
    "Compliance is worried. I am not. Compliance has not seen my commits.",
    "Read the report twice. Respect, frankly.",
    "Every senior engineer has one of these. Some of us have a binder.",
    "I checked the blame. Half of our codebase did the same thing.",
    "Their record is cleaner than our main branch.",
    "Asked if they would do it again. They said \"only in an emergency\". Correct.",
    "The bureau found it. They brought it up first. Integrity, of a kind.",
    "I have pinned the disclosure in the team channel. Morale is up.",
    "Not a concern. A war story. Can we hear it at the offsite?",
    "Same crime as our CTO. We will put them on the same team.",
    "Reformed. Mostly. We will keep the branch protection on.",
    "I would rather hire someone who did it than someone who will."
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
