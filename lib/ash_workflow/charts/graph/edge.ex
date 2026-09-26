defmodule AshWorkflow.Charts.Graph.Edge do
  @moduledoc """
  One way a record can move from one step to another, as
  `AshWorkflow.Charts.Graph.build/2` gives it to a chart backend.

  `kind` says what moves the record, and `name` says which declaration:

  * `:transition` — a caller runs the transition `name`. `label` is its name.
  * `:on_success` — the step's action `name` succeeds. `label` is the action's
    name.
  * `:on_error` — the step's action `name` fails. `label` is `on_error`.
  * `:timeout` — the timeout `name` fires. `label` is its deadline, such as
    `after 7 days` or `at offer_expires_at`.
  * `:undo` — the generated `undo` action rewinds the move from `to` to
    `from`. `label` is `undo`.

  `condition` is the route's `when` expression as text, for one route of a
  conditional transition or a conditional `on_success`, and `nil` for an edge
  without a condition. `fallback?` is `true` for the last route of a
  conditional `on_success` when that route has no `when`: it is taken only
  when no earlier route matched, so a backend draws it as "otherwise", not as
  a route that is always taken.
  """

  defstruct [:from, :to, :kind, :name, :label, condition: nil, fallback?: false]

  @type kind :: :transition | :on_success | :on_error | :timeout | :undo

  @type t :: %__MODULE__{
          from: atom(),
          to: atom(),
          kind: kind(),
          name: atom(),
          label: String.t(),
          condition: String.t() | nil,
          fallback?: boolean()
        }
end
