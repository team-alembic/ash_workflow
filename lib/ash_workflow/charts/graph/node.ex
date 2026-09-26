defmodule AshWorkflow.Charts.Graph.Node do
  @moduledoc """
  One step of a workflow, as `AshWorkflow.Charts.Graph.build/2` gives it to a
  chart backend.

  `kind` is what a backend styles a step by:

  * `:automatic` — the step runs an action on entry.
  * `:manual` — the step waits for a caller to run one of its transitions.
  * `:wait_state` — nothing runs on entry and no caller can move the record.
    A timeout is the only way out.
  * `:terminal` — an end state.

  `initial?` is `true` for the step the workflow starts in. `notes` holds what
  the step does without leaving it, so it has no edge: its policy, its retry
  policy, the timeouts that run an action, and its `every` entries.
  """

  defstruct [:id, :kind, initial?: false, notes: []]

  @type kind :: :automatic | :manual | :wait_state | :terminal

  @type t :: %__MODULE__{
          id: atom(),
          kind: kind(),
          initial?: boolean(),
          notes: [AshWorkflow.Charts.Graph.Note.t()]
        }
end
