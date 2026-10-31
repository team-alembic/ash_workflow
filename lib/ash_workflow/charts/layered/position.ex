defmodule AshWorkflow.Charts.Layered.Position do
  @moduledoc false
  # y: each rank is as tall as its tallest node, and half of rank_sep
  # separates two ranks, because every edge spans at least two ranks.
  # x: pack each rank left to right, then pull each node towards the mean x
  # of its neighbours, down then up, a few times. Each pull keeps the order
  # and the gaps: it is the mean of a left-to-right pass and a right-to-left
  # pass, and both passes keep the gaps, so their mean keeps them too.

  # As in Route: an edge through a label drawn over it stays this far inside
  # the label's sides.
  @corner_pad 8
  @port_gap 16
  @min_step 10
  @port_slots 0.6

  alias AshWorkflow.Charts.Layered.NetworkSimplex

  # {coords, lanes, ports}: coords maps each node to {x, y, w, h}; lanes
  # maps each label that slides along its edge to the x of the edge through
  # it; ports maps {:out | :in, edge id} to the x where the edge meets its
  # box, for the ends that slide.
  def run(graph, layers, opts) do
    {xs, lanes, split, ports} = xs(graph, layers, opts)
    ys = ys(graph, layers, lanes, opts)

    coords =
      Map.new(graph.nodes, fn {id, node} ->
        {id,
         {Map.fetch!(xs, id), Map.fetch!(ys, Map.fetch!(graph.ranks, id)), node.width,
          node.height}}
      end)

    {coords, Map.take(lanes, split), ports}
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

  # {box centres, lanes}: the two differ only for a label drawn over an
  # orthogonal edge, whose lane can pass the label anywhere in its column.
  defp xs(graph, layers, opts) do
    {raw, lanes, split, ports} =
      case opts[:placement] do
        :network_simplex -> simplex_xs(graph, layers, opts)
        _pull -> pull_xs(graph, layers, opts) |> then(&{&1, &1, [], %{}})
      end

    left =
      graph.nodes
      |> Enum.map(fn {id, node} -> Map.fetch!(raw, id) - node.width / 2 end)
      |> Enum.min()

    shift = &Map.new(&1, fn {id, x} -> {id, x - left + opts[:margin]} end)
    {shift.(raw), shift.(lanes), split, shift.(ports)}
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
  #
  # With slide: true (the default), an end of an edge can slide along its
  # box, and a label drawn over an orthogonal edge along its edge, because
  # the router does not need them centred: a port can sit anywhere in the
  # box side less 6 px at each corner, and an orthogonal edge can pass such a label
  # anywhere in its column (see Route.corner/1). Each port and each such
  # label box is a variable of its own, kept within its window by a pair of
  # edges with negative minlen, and pulled weakly (weight 1) to the centre.
  # So a lane runs straight into a box when it can, and pays for a step
  # only when no x in the window works.
  #
  # The cost is linear, so the optimum may leave a step of a few pixels,
  # which reads as a jog. Each such step is then made straight, or else at
  # least @min_step long, and the graph is solved again (see straighten/5).
  defp simplex_xs(graph, layers, opts) do
    off = fn id -> offset(graph.nodes[id]) end
    slide? = Keyword.get(opts, :slide, true)

    split =
      if slide? and opts[:routing] == :orthogonal,
        do: MapSet.new(for({id, %{side: :over}} <- graph.nodes, do: id)),
        else: MapSet.new()

    box = &if(MapSet.member?(split, &1), do: {:box, &1}, else: &1)

    # A companion lane keeps at least 24 px from its partner's lane, so the
    # two read as separate lines.
    paired = opts |> Keyword.get(:pairs, []) |> MapSet.new()

    separations =
      for {_rank, ids} <- Enum.sort(layers),
          [a, b] <- Enum.chunk_every(ids, 2, 1, :discard) do
        minlen = ceil(gap(graph.nodes[a], graph.nodes[b], opts) + off.(b) - off.(a))
        minlen = if MapSet.member?(paired, {a, b}), do: max(minlen, 24), else: minlen
        {box.(a), box.(b), minlen, 0}
      end

    windows =
      Enum.flat_map(split, fn id ->
        reach = floor(graph.nodes[id].width / 2 - min(@corner_pad, graph.nodes[id].width / 2))
        window({:box, id}, id, reach, {:centre, {:box, id}})
      end)

    # An end at a box goes through a port variable when it can slide. Its
    # window is the side less 6 px at each corner, as in Route.spread/3.
    port = fn i, kind, id ->
      node = graph.nodes[id]
      if slide? and node.dummy == nil, do: {{kind, i}, reach(node)}, else: nil
    end

    {aux, pulls, ends} =
      graph.segments
      |> Enum.with_index()
      |> Enum.reduce({[], [], []}, fn {{u, v}, i}, {aux, pulls, segment_ends} ->
        n = {:aux, i}
        w = omega(graph.nodes[u], graph.nodes[v])

        ends =
          for {kind, id} <- [out: u, in: v] do
            case port.(i, kind, id) do
              nil -> {id, []}
              {p, reach} -> {p, window(p, id, reach, {:centre, p})}
            end
          end

        [{a, wa}, {b, wb}] = ends
        {[n | aux], [{n, b, 0, w}, {n, a, 0, w} | wa ++ wb ++ pulls], [{a, b} | segment_ends]}
      end)

    # The ports of one side keep the gap Route.spread/3 gives them, in the
    # order of their other ends, so the router does not move them again.
    index = for {_rank, ids} <- layers, {id, i} <- Enum.with_index(ids), into: %{}, do: {id, i}

    # An undo lane and its partner keep 24 px apart at a box side too, as
    # in their lanes, when the side has room for it; so both can run
    # straight.
    pair_edges =
      for {{:dummy, a, _}, {:dummy, b, _}} <- Keyword.get(opts, :pairs, []),
          into: MapSet.new(),
          do: Enum.sort([a, b])

    edge_of = fn {u, v} ->
      [{:dummy, edge, _rank} | _] = Enum.filter([u, v], &match?({:dummy, _, _}, &1))
      edge
    end

    port_gaps =
      if slide? do
        graph.segments
        |> Enum.with_index()
        |> Enum.flat_map(fn {{u, v} = segment, i} ->
          for {kind, id, other} <- [{:out, u, v}, {:in, v, u}],
              graph.nodes[id].dummy == nil,
              do: {{kind, id}, {Map.fetch!(index, other), {kind, i}, edge_of.(segment)}}
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.flat_map(fn {{_kind, id}, ends} ->
          ports = Enum.sort(ends)
          room = 2 * reach(graph.nodes[id])
          k = length(ports)
          even = if k > 1, do: min(@port_gap, floor(room / (k - 1))), else: 0
          pairs = Enum.chunk_every(ports, 2, 1, :discard)

          wide =
            Enum.map(pairs, fn [{_, _, a}, {_, _, b}] ->
              if MapSet.member?(pair_edges, Enum.sort([a, b])), do: 24, else: @port_gap
            end)

          gaps = if Enum.sum(wide) <= room, do: wide, else: List.duplicate(even, length(pairs))
          for {[{_, a, _}, {_, b, _}], gap} <- Enum.zip(pairs, gaps), do: {a, b, gap, 0}
        end)
      else
        []
      end

    # A companion lane and its partner's lane pull together hard, so they
    # end exactly their minimum distance apart.
    {aux, pulls} =
      opts
      |> Keyword.get(:pairs, [])
      |> Enum.with_index()
      |> Enum.reduce({aux, pulls}, fn {{a, b}, i}, {aux, pulls} ->
        n = {:pair, i}
        {[n | aux], [{n, b, 0, 64}, {n, a, 0, 64} | pulls]}
      end)

    edges = separations ++ windows ++ port_gaps ++ Enum.reverse(pulls)
    extra = Enum.flat_map(edges, fn {a, b, _, _} -> [a, b] end) ++ Enum.reverse(aux)
    ids = Enum.flat_map(Enum.sort(layers), &elem(&1, 1))
    ids = ids ++ (extra |> Enum.uniq() |> Enum.reject(&MapSet.member?(MapSet.new(ids), &1)))

    solved = NetworkSimplex.run(ids, edges)

    solved =
      if slide? do
        ends = Enum.reverse(ends)
        {edges, solved} = straighten(ids, edges, ends, solved, 32)

        boxes =
          for {{u, v}, i} <- Enum.with_index(graph.segments),
              {p, box} <- [{{:out, i}, u}, {{:in, i}, v}],
              Map.has_key?(solved, p),
              into: %{},
              do: {p, box}

        {edges, solved} = tuck(ids, edges, ends, boxes, graph, solved)
        {_edges, solved} = straighten(ids, edges, ends, solved, 32)
        solved
      else
        solved
      end

    lanes = Map.new(graph.nodes, fn {id, _} -> {id, Map.fetch!(solved, id) - off.(id)} end)
    centres = Map.new(split, &{&1, Map.fetch!(solved, {:box, &1})})

    # Each port as {:out | :in, edge id} => x; the dummy in a segment names
    # its edge.
    ports =
      for {{u, v}, i} <- Enum.with_index(graph.segments),
          {kind, var} <- [out: {:out, i}, in: {:in, i}],
          Map.has_key?(solved, var),
          into: %{} do
        [{:dummy, edge, _rank} | _] = Enum.filter([u, v], &match?({:dummy, _, _}, &1))
        {{kind, edge}, Map.fetch!(solved, var)}
      end

    {Map.merge(lanes, centres), lanes, MapSet.to_list(split), ports}
  end

  # A port whose edge turns anyway moves in to the middle 60% of its side,
  # as in Route.spread/3, so no edge leaves from near a corner to turn; one
  # port at a time, where the constraints allow and no other segment
  # turns for it.
  defp tuck(ids, edges, ends, boxes, graph, solved) do
    Enum.reduce(ends, {edges, solved}, fn {a, b}, {edges, solved} ->
      [a, b]
      |> Enum.filter(&Map.has_key?(boxes, &1))
      |> Enum.reduce({edges, solved}, fn p, {edges, solved} ->
        box = Map.fetch!(boxes, p)
        reach = floor(graph.nodes[box].width * @port_slots / 2)
        turns? = Map.fetch!(solved, a) != Map.fetch!(solved, b)

        if turns? and abs(Map.fetch!(solved, p) - Map.fetch!(solved, box)) > reach do
          extra = [{box, p, -reach, 0}, {p, box, -reach, 0}]

          tucked =
            if NetworkSimplex.feasible?(ids, edges ++ extra),
              do: NetworkSimplex.run(ids, edges ++ extra)

          # Only when no other segment turns for it.
          if tucked && straight(tucked, ends) >= straight(solved, ends),
            do: {edges ++ extra, tucked},
            else: {edges, solved}
        else
          {edges, solved}
        end
      end)
    end)
  end

  defp straight(solved, ends),
    do: Enum.count(ends, fn {a, b} -> Map.fetch!(solved, a) == Map.fetch!(solved, b) end)

  # A step shorter than @min_step between the two ends of a segment becomes
  # straight if the constraints allow, or else at least @min_step long, one
  # at a time.
  defp straighten(_ids, edges, _ends, solved, 0), do: {edges, solved}

  defp straighten(ids, edges, ends, solved, rounds) do
    small =
      Enum.find(ends, fn {a, b} ->
        step = abs(Map.fetch!(solved, a) - Map.fetch!(solved, b))
        step > 0 and step < @min_step
      end)

    case small do
      nil ->
        {edges, solved}

      {a, b} ->
        {low, high} = if Map.fetch!(solved, a) < Map.fetch!(solved, b), do: {a, b}, else: {b, a}
        straight = [{a, b, 0, 0}, {b, a, 0, 0}]
        # A step the way it goes, or else the other way.
        steps = [[{low, high, @min_step, 0}], [{high, low, @min_step, 0}]]
        rest = List.delete(ends, small)

        case Enum.find([straight | steps], &NetworkSimplex.feasible?(ids, edges ++ &1)) do
          nil ->
            straighten(ids, edges, rest, solved, rounds - 1)

          extra ->
            edges = edges ++ extra
            straighten(ids, edges, rest, NetworkSimplex.run(ids, edges), rounds - 1)
        end
    end
  end

  defp reach(node), do: floor(node.width / 2 - min(6, node.width / 4))

  # Edges that keep var within reach of centre on both sides, and a weak
  # pull (through the auxiliary node aux) of var towards centre.
  defp window(var, centre, reach, aux) do
    [
      {centre, var, -reach, 0},
      {var, centre, -reach, 0},
      {aux, var, 0, 1},
      {aux, centre, 0, 1}
    ]
  end

  # The segment into a step weighs 3, not 2: the last lane lines up with its
  # target, where a box side may be too short for a port to absorb a small
  # step; a small step at the source end moves the source's port instead.
  defp omega(%{dummy: nil}, %{dummy: nil}), do: 4
  defp omega(%{dummy: nil}, _), do: 12
  defp omega(_, %{dummy: nil}), do: 16
  defp omega(_, _), do: 32

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

  # An edge passes a label dummy along its left or right side, or through
  # its centre when the label is drawn over the edge (see Route), so the
  # pulls line that up with the neighbours.
  defp offset(%{dummy: :label, side: :left, width: w}), do: w / 2
  defp offset(%{dummy: :label, side: :over}), do: 0
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
