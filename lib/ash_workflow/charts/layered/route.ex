defmodule AshWorkflow.Charts.Layered.Route do
  @moduledoc false
  # Turns each edge's chain into points. An edge leaves the bottom of its
  # upper node and enters the top of its lower node. It passes the left side
  # of its label dummy, so the label sits to the right of the line. A
  # reversed edge gets its points reversed, so every edge runs from its own
  # source to its own target. A self-loop is a small loop on the right of its
  # node.

  alias AshWorkflow.Charts.Layered.Result

  @loop 24

  def run(graph, coords, reversed, loops, opts) do
    nodes = for {id, %{dummy: nil}} <- graph.nodes, into: %{}, do: {id, Map.fetch!(coords, id)}

    chained =
      Map.new(graph.chains, fn {edge_id, chain} ->
        {edge_id, chain_route(chain, graph, coords, MapSet.member?(reversed, edge_id))}
      end)

    looped =
      Map.new(loops, fn edge -> {edge.id, loop_route(edge, Map.fetch!(coords, edge.from))} end)

    edges = Map.merge(chained, looped)

    boxes =
      Enum.map(nodes, fn {_id, {x, y, w, h}} -> {x + w / 2, y + h / 2} end) ++
        for(%{label: {lx, ly, w, h}} <- Map.values(edges), do: {lx + w, ly + h / 2}) ++
        for(%{points: points} <- Map.values(edges), point <- points, do: point)

    %Result{
      nodes: nodes,
      edges: edges,
      reversed: reversed,
      width: (boxes |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 0 end)) + opts[:margin],
      height: (boxes |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)) + opts[:margin]
    }
  end

  defp chain_route(chain, graph, coords, reversed?) do
    last = length(chain) - 1

    {points, label} =
      chain
      |> Enum.with_index()
      |> Enum.map_reduce(nil, fn {id, i}, label ->
        {x, y, w, h} = Map.fetch!(coords, id)

        cond do
          i == 0 -> {{x, y + h / 2}, label}
          i == last -> {{x, y - h / 2}, label}
          graph.nodes[id].dummy == :label -> {{x - w / 2, y}, {x - w / 2 + 6, y, w, h}}
          true -> {{x, y}, label}
        end
      end)

    %{points: if(reversed?, do: Enum.reverse(points), else: points), label: label}
  end

  defp loop_route(edge, {x, y, w, _h}) do
    right = x + w / 2

    %{
      points: [{right, y - 8}, {right + @loop, y - 8}, {right + @loop, y + 8}, {right, y + 8}],
      label:
        if(edge.label_width > 0,
          do: {right + @loop + 4, y, edge.label_width, edge.label_height},
          else: nil
        )
    }
  end
end
