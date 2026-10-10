defmodule AshWorkflow.Charts.Format do
  @moduledoc """
  Writes DSL values out as the short phrases a chart shows.

  `AshWorkflow.Charts.Graph` calls the functions for DSL values, so every
  backend gets the same text for a deadline, a retry, a policy or a
  condition.

  `kind_text/1`, `node_text/1`, `edge_text/1` and `note_text/1` turn a node
  or an edge of the graph into a label. The Mermaid, D2 and DOT backends
  call them, so the three charts use the same words. A custom
  `AshWorkflow.Charts.Backend` can call them too.
  """

  alias AshWorkflow.Entities.Retry
  alias AshWorkflow.Entities.Undo

  @doc """
  A duration tuple as text, in the singular for one unit: `{1, :days}` is
  "1 day" and `{7, :days}` is "7 days".
  """
  @spec duration(AshWorkflow.Duration.t()) :: String.t()
  def duration({1, unit}), do: "1 #{singular(unit)}"
  def duration({value, unit}), do: "#{value} #{unit}"

  defp singular(:seconds), do: "second"
  defp singular(:minutes), do: "minute"
  defp singular(:hours), do: "hour"
  defp singular(:days), do: "day"

  @doc """
  The deadline of a timeout entry from `AshWorkflow.Info.workflow_graph/1`.
  """
  @spec deadline(map()) :: String.t()
  def deadline(%{fire_at: field}) when not is_nil(field), do: "at #{field}"

  def deadline(%{fire_after: duration, field: field}) when field in [nil, :state_entered_at],
    do: "after #{duration(duration)}"

  def deadline(%{fire_after: duration, field: field}),
    do: "#{duration(duration)} after #{field}"

  @doc """
  The schedule of an `every` entry from `AshWorkflow.Info.workflow_graph/1`.
  """
  @spec every(map()) :: String.t()
  def every(%{interval: interval, until: nil}), do: "every #{duration(interval)}"

  def every(%{interval: interval, until: until}),
    do: "every #{duration(interval)} for #{duration(until)}"

  @doc """
  The label of an undo edge, with the window when the `undo` block sets
  `within`: "undo" or "undo within 1 hour".
  """
  @spec undo(Undo.t()) :: String.t()
  def undo(%Undo{within: nil}), do: "undo"
  def undo(%Undo{within: within}), do: "undo within #{duration(within)}"

  @doc """
  The retry policy of a step, or `nil` when the step makes one attempt only.
  """
  @spec retry(Retry.t() | nil) :: String.t() | nil
  def retry(nil), do: nil
  def retry(%Retry{max_attempts: 1}), do: nil

  def retry(%Retry{max_attempts: attempts, backoff: :exponential}),
    do: "#{attempts} attempts, exponential backoff"

  def retry(%Retry{max_attempts: attempts, backoff: backoff}),
    do: "#{attempts} attempts, #{duration(backoff)} apart"

  @doc """
  A step's `policy` check, through the check's own `describe/1` when it has one.
  """
  @spec policy(term()) :: String.t() | nil
  def policy(nil), do: nil

  def policy({module, opts}) when is_atom(module) and is_list(opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :describe, 1) do
      templates(module.describe(opts))
    else
      inspect({module, opts})
    end
  end

  def policy(module) when is_atom(module), do: policy({module, []})
  def policy(other), do: templates(inspect(other))

  @doc """
  A route's `when` expression, or `nil` for a route without one.
  """
  @spec condition(term()) :: String.t() | nil
  def condition(nil), do: nil
  def condition(expression), do: templates(inspect(expression))

  @doc """
  The text of a step kind, as every chart labels a step: `"⚙\u{FE0F} automatic"`,
  `"✋ manual"` or `"⏳ wait state"`. The gear carries U+FE0F, so it draws as a
  colour emoji, the same as the other two.
  """
  @spec kind_text(:automatic | :manual | :wait_state) :: String.t()
  def kind_text(:automatic), do: "⚙\u{FE0F} automatic"
  def kind_text(:manual), do: "✋ manual"
  def kind_text(:wait_state), do: "⏳ wait state"

  @doc """
  The text inside a step box, for a chart that puts the notes in the step:
  the step's name, then `kind_text/1` on the next line, then the notes under
  a `—` rule, one per line, as `note_text/1` writes them.

  A terminal step has no kind line, but it keeps its notes.
  """
  @spec node_text(AshWorkflow.Charts.Graph.Node.t()) :: String.t()
  def node_text(%{kind: :terminal} = node),
    do: Enum.join([to_string(node.id) | notes_text(node.notes)], "\n—\n")

  def node_text(node),
    do: Enum.join(["#{node.id}\n#{kind_text(node.kind)}" | notes_text(node.notes)], "\n—\n")

  defp notes_text([]), do: []
  defp notes_text(notes), do: [Enum.map_join(notes, "\n", &note_text/1)]

  @doc """
  The label of an `AshWorkflow.Charts.Graph.Edge`: a symbol for its kind,
  then its text.

  * `⚙` for `on_success`, `✖` for `on_error`, `⏱` for a timeout and `↶` for
    undo. A transition has no symbol.
  * A timeout gives its name before its deadline: `⏱ auto_escalate after 4 hours`.
  * A conditional route adds `when` and its condition. The fallback route of
    a conditional `on_success` adds `otherwise`.

  Each backend draws this text and only escapes it for its own syntax. So all
  formats label an edge in the same words.
  """
  @spec edge_text(AshWorkflow.Charts.Graph.Edge.t()) :: String.t()
  def edge_text(%{kind: :timeout} = edge),
    do: edge_symbol(:timeout) <> "#{edge.name} " <> edge.label

  def edge_text(%{fallback?: true} = edge),
    do: edge_symbol(edge.kind) <> edge.label <> " otherwise"

  def edge_text(%{condition: nil} = edge), do: edge_symbol(edge.kind) <> edge.label

  def edge_text(edge),
    do: edge_symbol(edge.kind) <> edge.label <> " when " <> edge.condition

  defp edge_symbol(:transition), do: ""
  defp edge_symbol(:on_success), do: "⚙ "
  defp edge_symbol(:on_error), do: "✖ "
  defp edge_symbol(:timeout), do: "⏱ "
  defp edge_symbol(:undo), do: "↶ "

  @doc """
  The text of an `AshWorkflow.Charts.Graph.Note`.

  * A policy note is `policy:` and the check, and a retry note is `retry:` and
    the policy.
  * A timeout that runs an action is `⏱`, its deadline and the action.
  * An `every` is `↻`, its schedule and the action.

  A timeout or an `every` with its own retry adds `, retry:` and the policy.
  """
  @spec note_text(AshWorkflow.Charts.Graph.Note.t()) :: String.t()
  def note_text(%{kind: :policy, label: label}), do: "policy: " <> label
  def note_text(%{kind: :retry, label: label}), do: "retry: " <> label

  def note_text(%{kind: :timeout} = note),
    do: "⏱ #{note.label}: #{note.action}" <> note_retry(note)

  def note_text(%{kind: :every} = note), do: "↻ #{note.label}: #{note.action}" <> note_retry(note)

  defp note_retry(%{retry: nil}), do: ""
  defp note_retry(%{retry: retry}), do: ", retry: " <> retry

  # Ash stores `^actor(:role)` as the tuple `{:_actor, :role}` and `^tenant()`
  # as the atom `:_tenant`, and `inspect/1` writes those. Write them as the
  # templates the DSL shows. `^arg(...)` and `^context(...)` work as `^actor`.
  defp templates(text) do
    text
    |> String.replace(~r/\{:_(actor|arg|context), ([^{}]+?)\}/, "^\\1(\\2)")
    |> String.replace(~r/:_tenant\b/, "^tenant()")
  end
end
