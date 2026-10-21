defmodule AshWorkflow.Charts.Layered.Route do
  @moduledoc false
  # Turns each edge's chain into points.
  #
  # Each rank is a horizontal band as tall as its tallest box. An edge crosses
  # a band only as a vertical line: down the side of its label, or straight
  # through a rank where it passes no box of its own. All sideways travel
  # happens in the gaps between bands, where there are no boxes. So no edge
  # crosses a step or a label by construction.
  #
  # An edge leaves its source at a port on the bottom side and enters its
  # target at a port on the top side. The ports of one side are spread over
  # its middle part, in the order of the other ends, so arrowheads do not
  # meet at one point.
  #
  # In a gap, a :polyline or :spline edge goes straight from its exit to its
  # next entry; an :orthogonal edge goes down, across on a track of its own,
  # and down again. A reversed edge gets its points reversed, so every edge
  # runs from its own source to its own target. A self-loop is a loop on the
  # right of its node.

  alias AshWorkflow.Charts.Layered.Result

  @loop 24
  @track_gap 4
  @port_spread 0.6
  @label_inset 6

  def run(graph, coords, reversed, loops, opts) do
    nodes = for {id, %{dummy: nil}} <- graph.nodes, into: %{}, do: {id, Map.fetch!(coords, id)}
    bands = bands(graph, coords)
    ports = ports(graph, coords)

    routes =
      Map.new(graph.chains, fn {id, chain} ->
        {id, lanes(id, chain, graph, coords, bands, ports)}
      end)

    routed =
      case Keyword.get(opts, :routing, :polyline) do
        :orthogonal -> orthogonal(routes, bands)
        _straight -> Map.new(routes, fn {id, route} -> {id, straight(route)} end)
      end

    chained =
      Map.new(routed, fn {id, route} ->
        points = simplify(route.points)
        points = if MapSet.member?(reversed, id), do: Enum.reverse(points), else: points
        {id, %{route | points: points}}
      end)

    looped =
      Map.new(loops, fn edge -> {edge.id, loop_route(edge, Map.fetch!(coords, edge.from))} end)

    edges = Map.merge(chained, looped)

    corners =
      Enum.map(nodes, fn {_id, {x, y, w, h}} -> {x + w / 2, y + h / 2} end) ++
        for(%{label: {lx, ly, w, h}} <- Map.values(edges), do: {lx + w, ly + h / 2}) ++
        for(%{points: points} <- Map.values(edges), point <- points, do: point)

    %Result{
      nodes: nodes,
      edges: edges,
      reversed: reversed,
      width: (corners |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 0 end)) + opts[:margin],
      height: (corners |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)) + opts[:margin]
    }
  end

  @companion_gap 5

  # A companion edge, such as the undo of a transition, is not laid out. It
  # runs beside its partner's route, the other way, 5 px to the side away from
  # the partner's label. It has no label of its own.
  def companions(%Result{} = result, companions, routing) do
    edges =
      Enum.reduce(companions, result.edges, fn edge, edges ->
        partner = Map.fetch!(result.edges, edge.companion)

        Map.put(edges, edge.id, %{
          points: partner.points |> beside(routing) |> Enum.reverse(),
          label: nil
        })
      end)

    # A companion runs against its partner, so it counts as a back edge.
    reversed = Enum.reduce(companions, result.reversed, &MapSet.put(&2, &1.id))
    %{result | edges: edges, reversed: reversed}
  end

  # The route moved sideways by the gap, to the west. A straight route moves
  # only in x, so its diagonals stay inside their gaps and its lanes stay
  # vertical. An orthogonal route moves along its normals, to the west of a
  # line that runs down, whichever way the partner points; at a corner, the
  # point moves along the mean of the two normals, far enough to keep the gap
  # on both segments.
  defp beside(points, routing) when routing != :orthogonal,
    do: Enum.map(points, fn {x, y} -> {x - @companion_gap, y} end)

  defp beside(points, :orthogonal) do
    {_x0, y0} = hd(points)
    {_xn, yn} = List.last(points)
    d = if y0 > yn, do: -@companion_gap, else: @companion_gap

    normals =
      points
      |> Enum.zip(tl(points))
      |> Enum.map(fn {{x1, y1}, {x2, y2}} ->
        length = :math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2)
        if length == 0, do: {0.0, 0.0}, else: {-(y2 - y1) / length, (x2 - x1) / length}
      end)

    at_points =
      [hd(normals)] ++ Enum.map(Enum.zip(normals, tl(normals)), &corner/1) ++ [List.last(normals)]

    points
    |> Enum.zip(at_points)
    |> Enum.map(fn {{x, y}, {nx, ny}} -> {x + nx * d, y + ny * d} end)
  end

  defp corner({{ax, ay}, {bx, by}}) do
    {mx, my} = {ax + bx, ay + by}
    length = :math.sqrt(mx * mx + my * my)

    if length < 1.0e-9 do
      {ax, ay}
    else
      {mx, my} = {mx / length, my / length}
      scale = 1 / max(mx * ax + my * ay, 0.5)
      {mx * scale, my * scale}
    end
  end

  # %{rank => {top, bottom}}: the band that the rank's boxes fill.
  defp bands(graph, coords) do
    coords
    |> Enum.group_by(fn {id, _} -> Map.fetch!(graph.ranks, id) end, fn {_id, {_x, y, _w, h}} ->
      {y - h / 2, y + h / 2}
    end)
    |> Map.new(fn {rank, spans} ->
      {rank,
       {spans |> Enum.map(&elem(&1, 0)) |> Enum.min(),
        spans |> Enum.map(&elem(&1, 1)) |> Enum.max()}}
    end)
  end

  # %{{:out | :in, edge_id} => x offset from the node's centre}.
  defp ports(graph, coords) do
    out_side =
      Enum.group_by(graph.chains, fn {_id, chain} -> hd(chain) end, fn {id, chain} ->
        {id, Enum.at(chain, 1)}
      end)

    in_side =
      Enum.group_by(graph.chains, fn {_id, chain} -> List.last(chain) end, fn {id, chain} ->
        {id, Enum.at(chain, -2)}
      end)

    Map.new(spread(out_side, :out, coords) ++ spread(in_side, :in, coords))
  end

  defp spread(sides, kind, coords) do
    Enum.flat_map(sides, fn {node, ends} ->
      {_x, _y, w, _h} = Map.fetch!(coords, node)
      sorted = Enum.sort_by(ends, fn {id, other} -> {elem(Map.fetch!(coords, other), 0), id} end)
      k = length(sorted)
      # The middle 60% of the side, widened up to 90% so ports keep 16 px
      # apart: room for an undo line beside each one.
      spread = ((k + 1) * 16 / w) |> max(@port_spread) |> min(0.9)

      sorted
      |> Enum.with_index()
      |> Enum.map(fn {{id, _other}, i} ->
        {{kind, id}, ((i + 1) / (k + 1) - 0.5) * w * spread}
      end)
    end)
  end

  # The vertical lane pieces of one edge, from its upper end to its lower end:
  # [{rank, top_point, bottom_point}], and its label box.
  defp lanes(edge_id, chain, graph, coords, bands, ports) do
    last = length(chain) - 1

    {lanes, label} =
      chain
      |> Enum.with_index()
      |> Enum.map_reduce(nil, fn {id, i}, label ->
        {x, y, w, h} = Map.fetch!(coords, id)
        rank = Map.fetch!(graph.ranks, id)
        {top, bottom} = Map.fetch!(bands, rank)

        cond do
          # A box shorter than its rank leaves and enters vertically, so the
          # edge does not cut across a taller neighbour in the same band.
          i == 0 ->
            px = x + Map.get(ports, {:out, edge_id}, 0)
            {{rank, {px, y + h / 2}, {px, bottom}}, label}

          i == last ->
            px = x + Map.get(ports, {:in, edge_id}, 0)
            {{rank, {px, top}, {px, y - h / 2}}, label}

          graph.nodes[id].dummy == :label ->
            line = x - w / 2
            {{rank, {line, top}, {line, bottom}}, {line + @label_inset, y, w, h}}

          true ->
            {{rank, {x, top}, {x, bottom}}, label}
        end
      end)

    %{lanes: lanes, label: label}
  end

  defp straight(%{lanes: lanes, label: label}) do
    %{points: Enum.flat_map(lanes, fn {_rank, a, b} -> [a, b] end), label: label}
  end

  # In each gap, an edge that changes x goes down to its own track, across,
  # and down again. Tracks in one gap are assigned by interval colouring.
  defp orthogonal(routes, bands) do
    spans =
      for {id, %{lanes: lanes}} <- Enum.sort(routes),
          {{{rank, _top, {x1, _y1}}, {_rank2, {x2, _y2}, _bottom}}, i} <-
            Enum.with_index(Enum.zip(lanes, tl(lanes))),
          abs(x1 - x2) >= 0.5,
          do: {rank, {id, i}, x1, x2}

    tracks = tracks(spans, bands)

    Map.new(routes, fn {id, %{lanes: lanes, label: label}} ->
      gaps =
        lanes
        |> Enum.zip(tl(lanes))
        |> Enum.with_index()
        |> Enum.flat_map(fn {{{_r1, top, {x1, y1}}, {_r2, {x2, _y2}, _bottom}}, i} ->
          case Map.fetch(tracks, {id, i}) do
            {:ok, y} -> [top, {x1, y1}, {x1, y}, {x2, y}]
            :error -> [top, {x1, y1}]
          end
        end)

      {_rank, top, bottom} = List.last(lanes)
      {id, %{points: gaps ++ [top, bottom], label: label}}
    end)
  end

  # Track order in one gap, after Sander (1996): a segment whose upper
  # vertical (at x1) falls inside another segment's horizontal span must run
  # above it, and one whose lower vertical (at x2) falls inside must run below
  # it; otherwise a vertical crosses a horizontal. Those rules form a graph;
  # its cycles are crossings no order avoids, and a depth-first search breaks
  # them. Each segment then takes the first level below all its
  # predecessors where it overlaps no segment already there.
  defp tracks(spans, bands) do
    spans
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.sort()
    |> Enum.flat_map(fn {rank, group} ->
      levels = levels(group)
      k = (levels |> Map.values() |> Enum.max(fn -> 0 end)) + 1
      {_top, gap_top} = Map.fetch!(bands, rank)
      {gap_bottom, _bottom} = Map.fetch!(bands, rank + 1)

      Enum.map(levels, fn {key, level} ->
        {key, gap_top + (gap_bottom - gap_top) * (level + 1) / (k + 1)}
      end)
    end)
    |> Map.new()
  end

  defp levels(group) do
    inside? = fn x, {_r, _key, a, b} -> x > min(a, b) + 0.5 and x < max(a, b) - 0.5 end

    above =
      for {_r, ka, x1, x2} <- group, {_r2, kb, _, _} = b <- group, ka != kb, reduce: [] do
        acc ->
          acc = if inside?.(x1, b), do: [{ka, kb} | acc], else: acc
          if inside?.(x2, b), do: [{kb, ka} | acc], else: acc
      end
      |> Enum.uniq()
      |> acyclic(Enum.map(group, &elem(&1, 1)))

    preds = Enum.group_by(above, &elem(&1, 1), &elem(&1, 0))
    spans = Map.new(group, fn {_r, key, x1, x2} -> {key, {min(x1, x2), max(x1, x2)}} end)

    group
    |> Enum.map(&elem(&1, 1))
    |> topological(above)
    |> Enum.reduce(%{}, fn key, levels ->
      floor =
        preds
        |> Map.get(key, [])
        |> Enum.map(&(Map.fetch!(levels, &1) + 1))
        |> Enum.max(fn -> 0 end)

      {left, right} = Map.fetch!(spans, key)

      level =
        Stream.iterate(floor, &(&1 + 1))
        |> Enum.find(fn level ->
          not Enum.any?(levels, fn {other, l} ->
            {ol, or_} = Map.fetch!(spans, other)
            l == level and ol < right + @track_gap and left < or_ + @track_gap
          end)
        end)

      Map.put(levels, key, level)
    end)
  end

  # Drops each rule that closes a cycle, found by a depth-first search in key
  # order.
  defp acyclic(rules, keys) do
    out = Enum.group_by(rules, &elem(&1, 0), &elem(&1, 1))

    {_seen, dropped} =
      Enum.reduce(keys, {MapSet.new(), MapSet.new()}, fn key, acc ->
        dfs(key, out, MapSet.new(), acc)
      end)

    Enum.reject(rules, &MapSet.member?(dropped, &1))
  end

  defp dfs(key, out, stack, {seen, dropped} = acc) do
    if MapSet.member?(seen, key) do
      acc
    else
      stack = MapSet.put(stack, key)

      out
      |> Map.get(key, [])
      |> Enum.reduce({MapSet.put(seen, key), dropped}, fn to, {seen, dropped} ->
        if MapSet.member?(stack, to),
          do: {seen, MapSet.put(dropped, {key, to})},
          else: dfs(to, out, stack, {seen, dropped})
      end)
    end
  end

  defp topological(keys, rules) do
    indegree =
      Enum.reduce(rules, Map.new(keys, &{&1, 0}), fn {_a, b}, acc ->
        Map.update!(acc, b, &(&1 + 1))
      end)

    out = Enum.group_by(rules, &elem(&1, 0), &elem(&1, 1))
    take(keys, indegree, out, [])
  end

  defp take(keys, indegree, out, acc) do
    case Enum.find(keys, &(Map.fetch!(indegree, &1) == 0)) do
      nil ->
        Enum.reverse(acc)

      key ->
        indegree =
          out
          |> Map.get(key, [])
          |> Enum.reduce(indegree, fn b, acc -> Map.update!(acc, b, &(&1 - 1)) end)

        take(List.delete(keys, key), indegree, out, [key | acc])
    end
  end

  # Drops repeated points and points on a straight line between their
  # neighbours, so a route has only the segments a reader sees.
  defp simplify(points) do
    points
    |> Enum.dedup()
    |> drop_collinear()
  end

  defp drop_collinear([a, b, c | rest]) do
    if collinear?(a, b, c),
      do: drop_collinear([a, c | rest]),
      else: [a | drop_collinear([b, c | rest])]
  end

  defp drop_collinear(points), do: points

  defp collinear?({ax, ay}, {bx, by}, {cx, cy}),
    do: abs((bx - ax) * (cy - by) - (by - ay) * (cx - bx)) < 1.0e-6

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
