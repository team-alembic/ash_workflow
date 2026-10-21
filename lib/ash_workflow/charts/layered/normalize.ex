defmodule AshWorkflow.Charts.Layered.Normalize do
  @moduledoc false
  # Splits every edge into one-rank segments through dummy nodes. The dummy at
  # the edge's middle rank has the label's size, so the label gets its own
  # room in the layout.
  #
  # nodes:    %{id => %{width, height, dummy: nil | :edge | :label}}
  # ids:      the real node ids, in input order
  # segments: [{upper_id, lower_id}], each one rank long, in edge order
  # chains:   %{edge_id => [node ids from the upper end to the lower end]}

  defstruct nodes: %{}, ids: [], edge_ids: [], ranks: %{}, segments: [], chains: %{}

  def run(nodes, edges, ranks) do
    base = %__MODULE__{
      nodes: Map.new(nodes, &{&1.id, %{width: &1.width, height: &1.height, dummy: nil}}),
      ids: Enum.map(nodes, & &1.id),
      ranks: ranks
    }

    Enum.reduce(edges, base, &add_edge/2)
  end

  defp add_edge(edge, graph) do
    from = Map.fetch!(graph.ranks, edge.from)
    to = Map.fetch!(graph.ranks, edge.to)
    label_rank = from + div(to - from, 2)

    dummies =
      for rank <- (from + 1)..(to - 1)//1 do
        if rank == label_rank,
          do: {{:dummy, edge.id, rank}, rank, edge.label_width, edge.label_height, :label},
          else: {{:dummy, edge.id, rank}, rank, 0, 0, :edge}
      end

    chain = [edge.from] ++ Enum.map(dummies, &elem(&1, 0)) ++ [edge.to]

    graph =
      Enum.reduce(dummies, graph, fn {id, rank, w, h, kind}, graph ->
        %{
          graph
          | nodes: Map.put(graph.nodes, id, %{width: w, height: h, dummy: kind}),
            ranks: Map.put(graph.ranks, id, rank)
        }
      end)

    %{
      graph
      | segments: graph.segments ++ Enum.zip(chain, tl(chain)),
        chains: Map.put(graph.chains, edge.id, chain),
        edge_ids: graph.edge_ids ++ [edge.id]
    }
  end
end
