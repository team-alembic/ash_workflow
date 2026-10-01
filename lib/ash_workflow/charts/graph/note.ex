defmodule AshWorkflow.Charts.Graph.Note do
  @moduledoc """
  Something a step does without leaving it, attached to its
  `AshWorkflow.Charts.Graph.Node`.

  * `:policy` — the step's `policy` check. `label` is the check's own
    description, such as `actor.role == :reviewer`.
  * `:retry` — the step's `retry` block, when it allows more than one attempt.
    `label` reads like `3 attempts, 10 seconds apart`.
  * `:timeout` — a timeout that runs `action` and stays in the step. `name` is
    the timeout's name, and `label` is its deadline, such as `after 2 days`.
  * `:every` — an `every` entry that runs `action`. `name` is its name, and
    `label` is its schedule, such as `every 1 hour for 3 hours`.

  A `:timeout` or `:every` note also carries `retry`: its own retry policy,
  worded as a `:retry` note is, or `nil` when it makes one attempt.
  """

  defstruct [:kind, :label, name: nil, action: nil, retry: nil]

  @type kind :: :policy | :retry | :timeout | :every

  @type t :: %__MODULE__{
          kind: kind(),
          label: String.t(),
          name: atom() | nil,
          action: atom() | nil,
          retry: String.t() | nil
        }
end
