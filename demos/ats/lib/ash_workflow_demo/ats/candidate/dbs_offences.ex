defmodule AshWorkflowDemo.ATS.Candidate.DbsOffences do
  @moduledoc """
  The disclosures the fake bureau can return.

  Every one of these is a crime against a codebase rather than a crime, which
  is deliberate: the candidate on the projector is a real person in the room,
  and the joke has to be about the profession rather than about them. Keep it
  that way when adding more.
  """

  @offences [
    "Committed directly to main. Repeatedly. 2019 to present.",
    "Force-pushed a shared branch and said nothing for a week.",
    "Tabs. In a Python codebase. Persistent offender.",
    "Named a variable `data2`, then named the next one `data2_final`.",
    "Merged a pull request titled `fix`.",
    "Left `console.log('here')` in production for eleven months.",
    "Answered \"it works on my machine\" under oath.",
    "Rewrote a working service in a language nobody else on the team knew.",
    "Declared a migration would take twenty minutes. It ran for nine days.",
    "Used `git push --force` on a Friday at 16:58.",
    "Catch block containing only a comment reading `// TODO`.",
    "Wrote a regex to parse HTML, then showed it to people.",
    "Set the on-call phone to silent. Twice.",
    "Insisted the test suite was flaky. The test was correct.",
    "Reviewed a 4,000 line pull request in ninety seconds with \"LGTM 🚀\".",
    "Disabled the linter in CI and called the commit `chore: tidy up`.",
    "Stored a production credential in a file named `notes.txt`.",
    "Theft of one traffic cone, 2011. Unrelated, but disclosed."
  ]

  @spec all() :: [String.t()]
  def all, do: @offences

  @spec random() :: String.t()
  def random, do: Enum.random(@offences)
end
