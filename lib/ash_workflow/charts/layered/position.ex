defmodule AshWorkflow.Charts.Layered.Position do
  @moduledoc false
  # y: each rank is as tall as its tallest node, and half of rank_sep
  # separates two ranks, because every edge spans at least two ranks.
  # x: pack each rank left to right, then pull each node towards the mean x
  # of its neighbours, down then up, a few times. Each pull keeps the order
  # and the gaps: it is the mean of a left-to-right pass and a right-to-left
  # pass, and both passes keep the gaps, so their mean keeps them too.

  def run(graph, layers, opts) do
    xs = xs(graph, layers, opts)
    ys = ys(graph, layers, xs, opts)

    Map.new(graph.nodes, fn {id, node} ->
      {id,
       {Map.fetch!(xs, id), Map.fetch!(ys, Map.fetch!(graph.ranks, id)), node.width, node.height}}
    end)
  end

  # The gap under a rank grows with the sideways travel of the edges that
  # cross it, so no diagonal is flatter than 1 in 4, and with the number of
  # edges that travel sideways, so orthogonal tracks keep 8 px apart. It is
  # never under half of rank_sep and never over twice rank_sep.
  defp ys(graph, layers, xs, opts) do
    line = fn id -> Map.fetch!(xs, id) + offset(graph.nodes[id]) end

    travel =
      Enum.group_by(graph.segments, fn {u, _v} -> Map.fetch!(graph.ranks, u) end, fn {u, v} ->
        abs(line.(u) - line.(v))
      end)

    {ys, _bottom} =
      layers
      |> Enum.sort()
      |> Enum.reduce({%{}, opts[:margin]}, fn {rank, ids}, {ys, top} ->
        height = ids |> Enum.map(&graph.nodes[&1].height) |> Enum.max(fn -> 0 end)
        moves = Map.get(travel, rank, [])
        sideways = Enum.count(moves, &(&1 >= 0.5))

        # Orthogonal tracks keep 12 px apart, and clear of the stubs at both
        # ends of the gap, up to 24 px each (an arrowhead can be at either
        # end, as back edges point up).
        tracks = if sideways > 0, do: (sideways + 1) * 12 + 48, else: 0

        gap =
          [opts[:rank_sep] / 2, Enum.max(moves, fn -> 0 end) / 4, tracks]
          |> Enum.max()
          |> min(opts[:rank_sep] * 2)

        {Map.put(ys, rank, top + height / 2), top + height + gap}
      end)

    ys
  end

  defp xs(graph, layers, opts) do
    raw =
      case opts[:placement] do
        :network_simplex -> simplex_xs(graph, layers, opts)
        _pull -> pull_xs(graph, layers, opts)
      end

    left =
      graph.nodes
      |> Enum.map(fn {id, node} -> Map.fetch!(raw, id) - node.width / 2 end)
      |> Enum.min()

    Map.new(raw, fn {id, x} -> {id, x - left + opts[:margin]} end)
  end

  defp pull_xs(graph, layers, opts) do
    preds = Enum.group_by(graph.segments, &elem(&1, 1), &elem(&1, 0))
    succs = Enum.group_by(graph.segments, &elem(&1, 0), &elem(&1, 1))
    ranks = layers |> Map.keys() |> Enum.sort()

    packed =
      Enum.reduce(ranks, %{}, fn rank, xs ->
        place(Map.fetch!(layers, rank), xs, graph, opts, fn _id -> 0 end)
      end)

    Enum.reduce(1..opts[:passes]//1, packed, fn _pass, xs ->
      xs
      |> pull(ranks, layers, preds, graph, opts)
      |> pull(Enum.reverse(ranks), layers, succs, graph, opts)
    end)
  end

  # Gansner et al. (1993), section 4.2, solved for the x of each edge's line:
  # a node's centre, or a label dummy's left side. For each segment u -> v, a
  # new node n gets edges n -> u and n -> v with minlen 0 and weight omega, so
  # the optimum pays omega * |line(u) - line(v)|. omega is 1 between two
  # steps, 2 next to a dummy and 8 between two dummies, which keeps long edges
  # straight. Neighbours in a rank get an edge left -> right with the gap as
  # minlen and weight 0. The solved ranks of this graph are the lines.
  defp simplex_xs(graph, layers, opts) do
    off = fn id -> offset(graph.nodes[id]) end

    # A companion lane keeps at least 24 px from its partner's lane, so the
    # two read as separate lines.
    paired = opts |> Keyword.get(:pairs, []) |> MapSet.new()

    separations =
      for {_rank, ids} <- Enum.sort(layers),
          [a, b] <- Enum.chunk_every(ids, 2, 1, :discard) do
        minlen = ceil(gap(graph.nodes[a], graph.nodes[b], opts) + off.(b) - off.(a))
        minlen = if MapSet.member?(paired, {a, b}), do: max(minlen, 24), else: minlen
        {a, b, minlen, 0}
      end

    {aux, pulls} =
      graph.segments
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {{u, v}, i}, {aux, pulls} ->
        n = {:aux, i}
        w = omega(graph.nodes[u], graph.nodes[v])
        {[n | aux], [{n, v, 0, w}, {n, u, 0, w} | pulls]}
      end)

    # A companion lane and its partner's lane pull together hard, so they
    # end exactly their minimum distance apart.
    {aux, pulls} =
      opts
      |> Keyword.get(:pairs, [])
      |> Enum.with_index()
      |> Enum.reduce({aux, pulls}, fn {{a, b}, i}, {aux, pulls} ->
        n = {:pair, i}
        {[n | aux], [{n, b, 0, 16}, {n, a, 0, 16} | pulls]}
      end)

    ids = Enum.flat_map(Enum.sort(layers), &elem(&1, 1)) ++ Enum.reverse(aux)

    ids
    |> AshWorkflow.Charts.Layered.NetworkSimplex.run(separations ++ Enum.reverse(pulls))
    |> Map.take(Map.keys(graph.nodes))
    |> Map.new(fn {id, line} -> {id, line - off.(id)} end)
  end

  # The segment into a step weighs 3, not 2: the last lane lines up with its
  # target, where a box side may be too short for a port to absorb a small
  # step; a small step at the source end moves the source's port instead.
  defp omega(%{dummy: nil}, %{dummy: nil}), do: 1
  defp omega(%{dummy: nil}, _), do: 2
  defp omega(_, %{dummy: nil}), do: 3
  defp omega(_, _), do: 8

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
  defp offset(%{dummy: :label, side: :left, width: w}), do: w / 2
  defp offset(%{dummy: :label, width: w}), do: -w / 2
  defp offset(_node), do: 0

  @doc false
  def line_offset(node), do: offset(node)

  # Half of each width, plus the mean of the two nodes' own separations. A
  # dummy that only carries an edge needs less room than a step or a label.
  defp gap(a, b, opts), do: (a.width + b.width) / 2 + (sep(a, opts) + sep(b, opts)) / 2

  defp sep(%{dummy: :edge}, opts), do: opts[:edge_sep]
  defp sep(_node, opts), do: opts[:node_sep]
end
