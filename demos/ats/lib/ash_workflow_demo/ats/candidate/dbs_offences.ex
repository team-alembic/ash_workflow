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
    "Ran `rm -rf` in the wrong terminal tab. Said \"oops\" in the post-mortem.",
    "Deployed on Christmas Eve. Went to lunch. Did not come back.",
    "Wrote a 600-line function called `handle`.",
    "Replied-all to a company-wide email with \"+1\".",
    "Shipped a feature flag that has been \"temporary\" since 2017.",
    "Upgraded every dependency at once. On a Friday. Without tests.",
    "Wrote a code comment that just says `// sorry`.",
    "Opened a pull request with 312 changed files and the description \"small fix\".",
    "Resolved a merge conflict by deleting both sides.",
    "Ran a migration against production thinking it was staging.",
    "Introduced a microservice. For the date picker.",
    "Committed `node_modules`. All of it.",
    "Wrote `SELECT *` on a table with forty billion rows. In prod. At peak.",
    "Silenced a failing test by renaming it `skip_this_one_lol`.",
    "Called a meeting that could have been a commit message.",
    "Pushed the `.env` file to a public repository. Got a lovely email from AWS.",
    "Marked a ticket \"done\" because the pull request had been opened.",
    "Introduced a new JavaScript framework to the team. Again.",
    "Estimated a task at \"two points\". It became a quarter.",
    "Wrote their own date library rather than read the docs for one.",
    "Left a TODO in 2014 with their name on it. Still assigned.",
    "Rebased the shared branch during the demo.",
    "Stored a production credential in a file named `notes.txt`.",
    "Theft of one traffic cone, 2011. Unrelated, but disclosed."
  ]

  @spec all() :: [String.t()]
  def all, do: @offences

  @spec random() :: String.t()
  def random, do: Enum.random(@offences)
end
