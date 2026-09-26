defmodule AshWorkflow.Charts.Json do
  @moduledoc """
  An `AshWorkflow.Charts.Graph` as plain data, for a client that draws the
  workflow itself: D3 with a layout library such as dagre or ELK.js,
  Cytoscape, React Flow, or a LiveView hook.

  `to_map/1` returns maps with string keys, and every value is a string, a
  boolean, `nil` or a list. Any JSON encoder can encode it, and a JavaScript
  client reads the same names:

      %{
        "resource" => "MyApp.Candidate",
        "nodes" => [
          %{"id" => "review", "kind" => "manual", "initial" => false,
            "notes" => [%{"kind" => "policy", "name" => nil, "action" => nil,
                          "label" => "actor.role == :reviewer", "retry" => nil}]}
        ],
        "edges" => [
          %{"from" => "review", "to" => "escalated", "kind" => "timeout",
            "name" => "escalation", "label" => "after 7 days", "condition" => nil,
            "fallback" => false}
        ]
      }

  `render/2` encodes that map with Jason.

  ## Options

  * `:pretty` — indent the JSON. Defaults to `false`.
  """

  @behaviour AshWorkflow.Charts.Backend

  alias AshWorkflow.Charts.Graph

  @impl true
  def file_extension, do: "json"

  @impl true
  def render(%Graph{} = graph, opts) do
    opts = Keyword.validate!(opts, pretty: false)
    Jason.encode_to_iodata!(to_map(graph), pretty: opts[:pretty])
  end

  @doc """
  The graph as maps with string keys, ready for any JSON encoder.
  """
  @spec to_map(Graph.t()) :: map()
  def to_map(%Graph{} = graph) do
    %{
      "resource" => inspect(graph.resource),
      "nodes" => Enum.map(graph.nodes, &node_map/1),
      "edges" => Enum.map(graph.edges, &edge_map/1)
    }
  end

  defp node_map(node) do
    %{
      "id" => string(node.id),
      "kind" => string(node.kind),
      "initial" => node.initial?,
      "notes" => Enum.map(node.notes, &note_map/1)
    }
  end

  defp note_map(note) do
    %{
      "kind" => string(note.kind),
      "name" => string(note.name),
      "action" => string(note.action),
      "label" => note.label,
      "retry" => note.retry
    }
  end

  defp edge_map(edge) do
    %{
      "from" => string(edge.from),
      "to" => string(edge.to),
      "kind" => string(edge.kind),
      "name" => string(edge.name),
      "label" => edge.label,
      "condition" => edge.condition,
      "fallback" => edge.fallback?
    }
  end

  defp string(nil), do: nil
  defp string(atom) when is_atom(atom), do: Atom.to_string(atom)
end
