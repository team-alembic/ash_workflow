defmodule AshWorkflow.Clarity.Diagram do
  @moduledoc false

  alias AshWorkflow.Charts.Graph
  alias AshWorkflow.Charts.Mermaid

  @kinds [:automatic, :manual, :wait_state, :terminal]

  @doc """
  The whole workflow as a Mermaid state diagram, with each step coloured by
  its kind.
  """
  @spec workflow(Ash.Resource.t(), :light | :dark) :: iodata()
  def workflow(resource, theme) do
    graph = Graph.build(resource)
    [Mermaid.render(graph, []), styles(graph.nodes, theme)]
  end

  @doc """
  The step, every step one move away from it, and the moves between them. The
  step itself is outlined and keeps its notes.
  """
  @spec neighbourhood(Ash.Resource.t(), atom(), :light | :dark) :: iodata()
  def neighbourhood(resource, step_name, theme) do
    graph = Graph.build(resource)
    edges = Enum.filter(graph.edges, &(step_name in [&1.from, &1.to]))
    neighbours = MapSet.new(edges, & &1.from) |> MapSet.union(MapSet.new(edges, & &1.to))

    nodes =
      for node <- graph.nodes, node.id == step_name or node.id in neighbours do
        if node.id == step_name, do: node, else: %{node | notes: []}
      end

    subgraph = %{graph | nodes: nodes, edges: edges}
    {[focus], others} = Enum.split_with(nodes, &(&1.id == step_name))

    [
      Mermaid.render(subgraph, []),
      styles(others, theme),
      # A state takes the styles of one class only, so the focused step gets its
      # kind's colours and the heavier outline together.
      "    classDef focus ",
      style(focus.kind, theme),
      ",stroke-width:4px,font-weight:bold\n",
      "    class ",
      Mermaid.state_id(step_name),
      " focus\n"
    ]
  end

  defp styles(nodes, theme) do
    groups = Enum.group_by(nodes, & &1.kind, &Mermaid.state_id(&1.id))

    for kind <- @kinds, ids = Map.get(groups, kind) do
      [
        "    classDef ",
        Atom.to_string(kind),
        " ",
        style(kind, theme),
        "\n    class ",
        Enum.join(ids, ","),
        " ",
        Atom.to_string(kind),
        "\n"
      ]
    end
  end

  defp style(:automatic, :light), do: "fill:#dcfce7,stroke:#16a34a,color:#14532d"
  defp style(:manual, :light), do: "fill:#dbeafe,stroke:#2563eb,color:#1e3a8a"
  defp style(:wait_state, :light), do: "fill:#fef3c7,stroke:#d97706,color:#78350f"
  defp style(:terminal, :light), do: "fill:#f3f4f6,stroke:#6b7280,color:#111827"
  defp style(:automatic, _dark), do: "fill:#14532d,stroke:#4ade80,color:#f0fdf4"
  defp style(:manual, _dark), do: "fill:#1e3a8a,stroke:#60a5fa,color:#eff6ff"
  defp style(:wait_state, _dark), do: "fill:#78350f,stroke:#fbbf24,color:#fffbeb"
  defp style(:terminal, _dark), do: "fill:#374151,stroke:#9ca3af,color:#f9fafb"
end
