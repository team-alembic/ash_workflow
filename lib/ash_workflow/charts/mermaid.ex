defmodule AshWorkflow.Charts.Mermaid do
  @moduledoc """
  Draws an `AshWorkflow.Charts.Graph` as a Mermaid `stateDiagram-v2`.

  GitHub, Livebook and ExDoc (with the script this library's own docs use)
  show the result without other tools.

  * Each step is declared as `state "review" as step_review`. The `step_`
    prefix keeps a step name such as `:note` or `:end` from being read as a
    Mermaid keyword. A character outside `A-Z`, `a-z`, `0-9` and `_` becomes
    `_` and its code point in hex. `render/2` raises `ArgumentError` if two
    step names still map to one ID, such as `:"re-open"` and `:re_2Dopen`.
  * Each step that is not terminal has a description line with its kind:
    `⚙ automatic`, `✋ manual` or `⏳ wait state`.
  * The initial step has an edge from `[*]`, and every terminal step has an
    edge to `[*]`.
  * An edge label starts with a symbol for its kind: `⚙` for `on_success`,
    `✖` for `on_error`, `⏱` for a timeout and `↶` for undo. A transition has
    no symbol. A conditional route adds `when` and its condition, and the
    fallback route of a conditional `on_success` adds `otherwise`.
  * A step's notes go in a `note right of` block: `policy:`, `retry:`, `⏱` for
    a timeout that runs an action, and `↻` for an `every`.

  A state diagram cannot draw a dashed or dotted edge, which is why the edge
  kind is in the label. The characters `#`, `;`, `<`, `>`, `"` and `\\` are written
  as Mermaid entity codes, such as `#60;` for `<`, so a condition such as
  `score < 3` cannot break the diagram. A `:` is written as `#58;` when another
  `:` follows it or when it ends the text, because Mermaid's label lexer stops
  at `::` and at a final `:`. A single `:` inside text, as in `:reviewer`,
  needs no code.

  This backend takes no options.
  """

  @behaviour AshWorkflow.Charts.Backend

  alias AshWorkflow.Charts.Graph

  @escapes %{
    "#" => "#35;",
    ";" => "#59;",
    "<" => "#60;",
    ">" => "#62;",
    "\"" => "#34;",
    "\\" => "#92;",
    "\n" => " "
  }
  @escape_keys Map.keys(@escapes)

  @impl true
  def file_extension, do: "mmd"

  @impl true
  def render(%Graph{} = graph, opts) do
    Keyword.validate!(opts, [])
    check_ids!(graph)

    [
      "stateDiagram-v2\n",
      Enum.map(graph.nodes, &state_lines/1),
      Enum.map(graph.nodes, &start_line/1),
      Enum.map(graph.edges, &edge_line/1),
      Enum.map(graph.nodes, &note_lines/1),
      Enum.map(graph.nodes, &end_line/1)
    ]
  end

  defp state_lines(node) do
    [
      ["    state \"", escape(to_string(node.id)), "\" as ", id(node.id), "\n"],
      kind_line(node)
    ]
  end

  defp kind_line(%{kind: :terminal}), do: []
  defp kind_line(node), do: ["    ", id(node.id), " : ", kind_text(node.kind), "\n"]

  defp kind_text(:automatic), do: "⚙ automatic"
  defp kind_text(:manual), do: "✋ manual"
  defp kind_text(:wait_state), do: "⏳ wait state"

  defp start_line(%{initial?: true} = node), do: ["    [*] --> ", id(node.id), "\n"]
  defp start_line(_node), do: []

  defp edge_line(edge) do
    [
      "    ",
      id(edge.from),
      " --> ",
      id(edge.to),
      ": ",
      escape(edge_text(edge)),
      "\n"
    ]
  end

  defp edge_text(%{fallback?: true} = edge),
    do: edge_symbol(edge.kind) <> edge.label <> " otherwise"

  defp edge_text(%{condition: nil} = edge), do: edge_symbol(edge.kind) <> edge.label

  defp edge_text(edge),
    do: edge_symbol(edge.kind) <> edge.label <> " when " <> edge.condition

  defp edge_symbol(:transition), do: ""
  defp edge_symbol(:on_success), do: "⚙ "
  defp edge_symbol(:on_error), do: "✖ "
  defp edge_symbol(:timeout), do: "⏱ "
  defp edge_symbol(:undo), do: "↶ "

  defp note_lines(%{notes: []}), do: []

  defp note_lines(node) do
    [
      "    note right of ",
      id(node.id),
      "\n",
      Enum.map(node.notes, &["        ", escape(note_text(&1)), "\n"]),
      "    end note\n"
    ]
  end

  defp note_text(%{kind: :policy, label: label}), do: "policy: " <> label
  defp note_text(%{kind: :retry, label: label}), do: "retry: " <> label
  defp note_text(%{kind: :timeout} = note), do: "⏱ #{note.label}: #{note.action}" <> retry(note)
  defp note_text(%{kind: :every} = note), do: "↻ #{note.label}: #{note.action}" <> retry(note)

  defp retry(%{retry: nil}), do: ""
  defp retry(%{retry: retry}), do: ", retry: " <> retry

  defp end_line(%{kind: :terminal} = node), do: ["    ", id(node.id), " --> [*]\n"]
  defp end_line(_node), do: []

  defp id(step_name) do
    "step_" <>
      String.replace(to_string(step_name), ~r/[^A-Za-z0-9_]/u, fn <<char::utf8>> ->
        "_" <> Integer.to_string(char, 16)
      end)
  end

  # The hex encoding keeps ordinary names readable, but it is not one-to-one:
  # `:"re-open"` and `:re_2Dopen` both give `step_re_2Dopen`. Two steps on one
  # state would draw a wrong chart with no error, so refuse instead.
  defp check_ids!(graph) do
    graph.nodes
    |> Enum.group_by(&id(&1.id), & &1.id)
    |> Enum.filter(fn {_id, names} -> length(names) > 1 end)
    |> case do
      [] ->
        :ok

      clashes ->
        raise ArgumentError,
              "these step names map to the same Mermaid state ID: " <>
                Enum.map_join(clashes, "; ", fn {id, names} -> "#{inspect(names)} -> #{id}" end)
    end
  end

  defp escape(text) do
    text
    |> String.replace(@escape_keys, &Map.fetch!(@escapes, &1))
    |> String.replace(~r/:(?=:|$)/, "#58;")
  end
end
