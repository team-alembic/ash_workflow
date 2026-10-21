defmodule AshWorkflow.Charts.Layered.Position do
  @moduledoc false
  # y: each rank is as tall as its tallest node, and half of rank_sep
  # separates two ranks, because every edge spans at least two ranks.
  # x: pack each rank left to right, then pull each node towards the mean x
  # of its neighbours, down then up, a few times. Each pull keeps the order
  # and the gaps: it is the mean of a left-to-right pass and a right-to-left
  # pass, and both passes keep the gaps, so their mean keeps them too.

  def run(graph, layers, opts) do
    ys = ys(graph, layers, opts)
    xs = xs(graph, layers, opts)

    Map.new(graph.nodes, fn {id, node} ->
      {id,
       {Map.fetch!(xs, id), Map.fetch!(ys, Map.fetch!(graph.ranks, id)), node.width, node.height}}
    end)
  end

  defp ys(graph, layers, opts) do
    {ys, _bottom} =
      layers
      |> Enum.sort()
      |> Enum.reduce({%{}, opts[:margin]}, fn {rank, ids}, {ys, top} ->
        height = ids |> Enum.map(&graph.nodes[&1].height) |> Enum.max(fn -> 0 end)
        {Map.put(ys, rank, top + height / 2), top + height + opts[:rank_sep] / 2}
      end)

    ys
  end

  defp xs(graph, layers, opts) do
    preds = Enum.group_by(graph.segments, &elem(&1, 1), &elem(&1, 0))
    succs = Enum.group_by(graph.segments, &elem(&1, 0), &elem(&1, 1))
    ranks = layers |> Map.keys() |> Enum.sort()

    packed =
      Enum.reduce(ranks, %{}, fn rank, xs ->
        place(Map.fetch!(layers, rank), xs, graph, opts, fn _id -> 0 end)
      end)

    pulled =
      Enum.reduce(1..opts[:passes]//1, packed, fn _pass, xs ->
        xs
        |> pull(ranks, layers, preds, graph, opts)
        |> pull(Enum.reverse(ranks), layers, succs, graph, opts)
      end)

    left =
      graph.nodes
      |> Enum.map(fn {id, node} -> Map.fetch!(pulled, id) - node.width / 2 end)
      |> Enum.min()

    Map.new(pulled, fn {id, x} -> {id, x - left + opts[:margin]} end)
  end

  defp pull(xs, ranks, layers, neighbours, graph, opts) do
    Enum.reduce(ranks, xs, fn rank, xs ->
      place(Map.fetch!(layers, rank), xs, graph, opts, fn id ->
        case Map.get(neighbours, id, []) do
          [] ->
            Map.fetch!(xs, id)

          ns ->
            line =
              Enum.sum(Enum.map(ns, &(Map.fetch!(xs, &1) + offset(graph.nodes[&1])))) / length(ns)

            line - offset(graph.nodes[id])
        end
      end)
    end)
  end

  defp place([], xs, _graph, _opts, _desired), do: xs

  defp place(layer, xs, graph, opts, desired) do
    wanted = Enum.map(layer, desired)

    gaps =
      layer
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> gap(graph.nodes[a], graph.nodes[b], opts) end)

    left = scan(wanted, gaps, fn d, prev, g -> max(d, prev + g) end)

    right =
      wanted
      |> Enum.reverse()
      |> scan(Enum.reverse(gaps), fn d, prev, g -> min(d, prev - g) end)
      |> Enum.reverse()

    layer
    |> Enum.zip(Enum.zip(left, right))
    |> Enum.reduce(xs, fn {id, {l, r}}, xs -> Map.put(xs, id, (l + r) / 2) end)
  end

  defp scan([first | rest], gaps, fun) do
    rest
    |> Enum.zip(gaps)
    |> Enum.reduce([first], fn {d, g}, [prev | _] = acc -> [fun.(d, prev, g) | acc] end)
    |> Enum.reverse()
  end

  # An edge passes a label dummy along its left side, not its centre (see
  # Route), so the pulls line that side up with the neighbours.
  defp offset(%{dummy: :label, width: w}), do: -w / 2
  defp offset(_node), do: 0

  # Half of each width, plus the mean of the two nodes' own separations. A
  # dummy that only carries an edge needs less room than a step or a label.
  defp gap(a, b, opts), do: (a.width + b.width) / 2 + (sep(a, opts) + sep(b, opts)) / 2

  defp sep(%{dummy: :edge}, opts), do: opts[:edge_sep]
  defp sep(_node, opts), do: opts[:node_sep]
end
