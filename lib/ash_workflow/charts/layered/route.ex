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

  alias AshWorkflow.Charts.Layered.Position
  alias AshWorkflow.Charts.Layered.Result

  @loop 24
  @track_gap 4
  @label_inset 6
  @port_inset 6
  # An edge through a label drawn over it stays this far inside the label's sides.
  @corner_pad 8
  @stub 12
  # The stub before an arrowhead: the 10 px head plus 14 px of straight line.
  @arrow_stub 24

  def run(graph, coords, reversed, loops, opts) do
    nodes = for {id, %{dummy: nil}} <- graph.nodes, into: %{}, do: {id, Map.fetch!(coords, id)}
    bands = bands(graph, coords)
    ports = ports(graph, coords, Keyword.get(opts, :routing, :polyline))

    routes =
      Map.new(graph.chains, fn {id, chain} ->
        {id, lanes(id, chain, graph, coords, bands, ports, MapSet.member?(reversed, id))}
      end)

    routed =
      case Keyword.get(opts, :routing, :polyline) do
        :orthogonal -> orthogonal(routes, bands)
        :spline -> splines(routes, nodes)
        _straight -> Map.new(routes, fn {id, route} -> {id, straight(route)} end)
      end

    chained =
      Map.new(routed, fn {id, route} ->
        reversed? = MapSet.member?(reversed, id)

        {id,
         if(Map.has_key?(route, :curve),
           do: orient_curve(route, reversed?),
           else: orient(route, reversed?)
         )}
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
      loops: MapSet.new(loops, & &1.id),
      width: (corners |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 0 end)) + opts[:margin],
      height: (corners |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)) + opts[:margin]
    }
  end

  defp bezier({x0, y0}, {x1, y1}, {x2, y2}, {x3, y3}, t) do
    u = 1 - t

    f = fn p0, p1, p2, p3 ->
      u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
    end

    {f.(x0, x1, x2, x3), f.(y0, y1, y2, y3)}
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
  #
  # A port sits where its edge's lane meets the box side, so an edge that
  # comes straight down its lane enters with no sideways step. It moves only
  # as far as it must: inside the side, 6 px from each corner, and 16 px
  # from its neighbours, or closer when the side is too short for that. A
  # lane past a corner moves its port in to the middle part of the side.
  #
  # An orthogonal edge can run straight down a label drawn over it at any x
  # in the label's column (see corner/1), so both its ports aim at one x of
  # that column: one that both ends can reach if there is one.
  defp ports(graph, coords, routing) do
    line = fn id, chain ->
      {x, _y, w, _h} = Map.fetch!(coords, id)
      node = graph.nodes[id]

      if routing == :orthogonal and Map.get(node, :side) == :over do
        i = Enum.find_index(chain, &(&1 == id))
        through(graph, coords, {x, w}, Enum.at(chain, i - 1), Enum.at(chain, i + 1))
      else
        x + Position.line_offset(node)
      end
    end

    out_side =
      Enum.group_by(graph.chains, fn {_id, chain} -> hd(chain) end, fn {id, chain} ->
        {id, line.(Enum.at(chain, 1), chain)}
      end)

    in_side =
      Enum.group_by(graph.chains, fn {_id, chain} -> List.last(chain) end, fn {id, chain} ->
        {id, line.(Enum.at(chain, -2), chain)}
      end)

    Map.new(spread(out_side, :out, coords) ++ spread(in_side, :in, coords))
  end

  # The x where an orthogonal edge runs down a label drawn over it: within
  # the label's column and, when it can be, within reach of the ends above
  # and below, so the edge passes the label as one straight line.
  defp through(graph, coords, {x, w}, above, below) do
    pad = min(@corner_pad, w / 2)
    column = {x - w / 2 + pad, x + w / 2 - pad}
    reach = fn id -> reach(graph.nodes[id], Map.fetch!(coords, id)) end
    {a_low, a_high} = reach.(above)
    {b_low, b_high} = reach.(below)
    {low, high} = column
    {both_low, both_high} = {Enum.max([low, a_low, b_low]), Enum.min([high, a_high, b_high])}

    if both_low <= both_high do
      (both_low + both_high) / 2
    else
      ((a_low + a_high + b_low + b_high) / 4) |> max(low) |> min(high)
    end
  end

  defp reach(%{dummy: nil}, {x, _y, w, _h}),
    do: {x - w / 2 + min(@port_inset, w / 4), x + w / 2 - min(@port_inset, w / 4)}

  defp reach(node, {x, _y, _w, _h}),
    do: {x + Position.line_offset(node), x + Position.line_offset(node)}

  @port_gap 16
  # Ports whose lanes are past a corner line up inside the middle 60% of the side.
  @port_slots 0.6

  defp spread(sides, kind, coords) do
    Enum.flat_map(sides, fn {node, ends} ->
      {x, _y, w, _h} = Map.fetch!(coords, node)
      inset = min(@port_inset, w / 4)
      {low, high} = {x - w / 2 + inset, x + w / 2 - inset}
      sorted = Enum.sort_by(ends, fn {id, lane} -> {lane, id} end)
      k = length(sorted)
      gap = if k > 1, do: min(@port_gap, (high - low) / (k - 1)), else: 0
      # A lane over the side keeps its port on the lane, so the edge stays
      # straight. Lanes past a corner must turn anyway, so their ports line up
      # from the edge of the middle part of the side inwards, not at the corner.
      reach = w * @port_slots / 2
      {before, rest} = Enum.split_while(sorted, fn {_id, lane} -> lane < low end)
      {over, beyond} = Enum.split_while(rest, fn {_id, lane} -> lane <= high end)

      lanes = Enum.map(over, &elem(&1, 1))
      first = Enum.min([x - reach + length(before) * gap | lanes]) - length(before) * gap
      last = Enum.max([x + reach - length(beyond) * gap | lanes]) + gap

      wanted =
        Enum.map(Enum.with_index(before), fn {_, j} -> first + j * gap end) ++
          lanes ++ Enum.map(Enum.with_index(beyond), fn {_, j} -> last + j * gap end)

      left =
        wanted
        |> Enum.drop(1)
        |> Enum.reduce([hd(wanted)], fn d, [prev | _] = acc -> [max(d, prev + gap) | acc] end)
        |> Enum.reverse()

      right =
        wanted
        |> Enum.reverse()
        |> then(fn [first | rest] ->
          Enum.reduce(rest, [first], fn d, [prev | _] = acc -> [min(d, prev - gap) | acc] end)
        end)

      sorted
      |> Enum.zip(Enum.zip(left, right))
      |> Enum.map(fn {{id, _lane}, {l, r}} ->
        {{kind, id}, ((l + r) / 2) |> max(low) |> min(high) |> Kernel.-(x)}
      end)
    end)
  end

  # The vertical lane pieces of one edge, from its upper end to its lower end:
  # [{rank, top_point, bottom_point}], and its label box.
  defp lanes(edge_id, chain, graph, coords, bands, ports, reversed?) do
    last = length(chain) - 1
    # The arrowhead is at the lower end, or at the upper end of a reversed
    # edge; that end gets the longer stub.
    {upper_stub, lower_stub} = if reversed?, do: {@arrow_stub, @stub}, else: {@stub, @arrow_stub}

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
          # Each end has a straight stub of at least 12 px, so its arrow
          # (or undo marker) sits on a straight segment.
          i == 0 ->
            px = x + Map.get(ports, {:out, edge_id}, 0)
            {{rank, {px, y + h / 2}, {px, max(bottom, y + h / 2 + upper_stub)}, :end}, label}

          i == last ->
            px = x + Map.get(ports, {:in, edge_id}, 0)
            {{rank, {px, min(top, y - h / 2 - lower_stub)}, {px, y - h / 2}, :end}, label}

          graph.nodes[id].dummy == :label ->
            line = x + Position.line_offset(graph.nodes[id])

            box_left =
              case Map.get(graph.nodes[id], :side) do
                :left -> line - @label_inset - w
                :over -> line - w / 2
                _right -> line + @label_inset
              end

            kind = if Map.get(graph.nodes[id], :side) == :over, do: :over, else: :label
            {{rank, {line, top}, {line, bottom}, kind}, {box_left, y, w, h}}

          true ->
            {{rank, {x, top}, {x, bottom}, :edge}, label}
        end
      end)

    %{lanes: lanes, label: label}
  end

  defp orient(route, reversed?) do
    points = simplify(route.points)
    %{route | points: if(reversed?, do: Enum.reverse(points), else: points)}
  end

  defp orient_curve(route, false), do: route

  defp orient_curve(%{curve: curve} = route, true) do
    curve =
      curve
      |> Enum.reverse()
      |> Enum.map(fn
        {:line, a, b} -> {:line, b, a}
        {:cubic, a, c1, c2, b} -> {:cubic, b, c2, c1, a}
      end)

    %{route | curve: curve, points: Enum.reverse(route.points)}
  end

  # A curve that swings through a lane can clip a box or a label next to it.
  # Such an edge keeps all its lanes straight and curves only in the gaps.
  defp splines(routes, nodes) do
    labels =
      for {id, %{label: {lx, ly, w, h}}} <- routes, do: {id, {lx, ly - h / 2, lx + w, ly + h / 2}}

    boxes =
      Enum.map(nodes, fn {_id, {x, y, w, h}} -> {x - w / 2, y - h / 2, x + w / 2, y + h / 2} end)

    Map.new(routes, fn {id, route} ->
      swung = spline(route)
      others = for {other, box} <- labels, other != id, do: box

      clear? =
        swung.points
        |> Enum.drop(1)
        |> Enum.drop(-1)
        |> Enum.all?(fn {x, y} ->
          not Enum.any?(others ++ boxes, fn {l, t, r, b} ->
            x > l + 1 and x < r - 1 and y > t + 1 and y < b - 1
          end)
        end)

      {id, if(clear?, do: swung, else: spline(route, :straight_lanes))}
    end)
  end

  # A curved edge keeps its stubs and the lanes beside its labels straight.
  # Every other lane shrinks to its middle point, and the edge swings through
  # it, so a long edge is one smooth curve, not a straight line with bends.
  # Between those pieces: cubics with vertical tangents. :curve holds the
  # drawing; :points holds it sampled, so the scorecard checks what is drawn.
  defp spline(route, lanes \\ :swing)

  defp spline(%{lanes: lanes, label: label}, mode) do
    pieces =
      Enum.map(lanes, fn
        {_rank, {x, top}, {_x, bottom}, :edge} when mode == :swing ->
          {:through, {x, (top + bottom) / 2}}

        {_rank, a, b, _kind} ->
          {:straight, a, b}
      end)

    [{:straight, first, _} | _] = pieces

    {curve, _at} =
      Enum.reduce(pieces, {[], first}, fn
        {:straight, a, b}, {acc, at} -> {[{:line, a, b} | swing(at, a, acc)], b}
        {:through, p}, {acc, at} -> {swing(at, p, acc), p}
      end)

    curve = Enum.reverse(curve)
    %{curve: curve, points: sample(curve), label: label}
  end

  @swing 0.5

  defp swing(from, to, acc) when from == to, do: acc

  defp swing({x1, y1} = from, {x2, y2} = to, acc) do
    reach = (y2 - y1) * @swing
    [{:cubic, from, {x1, y1 + reach}, {x2, y2 - reach}, to} | acc]
  end

  defp sample(curve) do
    points =
      Enum.flat_map(curve, fn
        {:line, a, _b} -> [a]
        {:cubic, a, c1, c2, b} -> for t <- Enum.map(0..7, &(&1 / 8)), do: bezier(a, c1, c2, b, t)
      end)

    last =
      case List.last(curve) do
        {:line, _a, b} -> b
        {:cubic, _a, _c1, _c2, b} -> b
      end

    Enum.dedup(points ++ [last])
  end

  defp straight(%{lanes: lanes, label: label}) do
    %{points: Enum.flat_map(lanes, fn {_rank, a, b, _kind} -> [a, b] end), label: label}
  end

  # In each gap, an edge that changes x goes down to its own track, across,
  # and down again. Tracks in one gap are assigned by interval colouring.
  defp orthogonal(routes, bands) do
    routes = Map.new(routes, fn {id, route} -> {id, corner(route)} end)

    spans =
      for {id, %{lanes: lanes}} <- Enum.sort(routes),
          {{{rank, _top, {x1, _y1}, _k1}, {_rank2, {x2, _y2}, _bottom, _k2}}, i} <-
            Enum.with_index(Enum.zip(lanes, tl(lanes))),
          abs(x1 - x2) >= 0.5,
          do: {rank, {id, i}, x1, x2}

    tracks = tracks(spans, bands)

    Map.new(routes, fn {id, %{lanes: lanes, label: label}} ->
      gaps =
        lanes
        |> Enum.zip(tl(lanes))
        |> Enum.with_index()
        |> Enum.flat_map(fn {{{_r1, top, {x1, y1}, _k1}, {_r2, {x2, _y2}, _bottom, _k2}}, i} ->
          case Map.fetch(tracks, {id, i}) do
            {:ok, y} -> [top, {x1, y1}, {x1, y}, {x2, y}]
            :error -> [top, {x1, y1}]
          end
        end)

      {_rank, top, bottom, _kind} = List.last(lanes)
      {id, %{points: gaps ++ [top, bottom], label: label}}
    end)
  end

  # An orthogonal edge under a label drawn over it runs straight down the
  # label's column, so the label never hides a turn: a reader sees the line
  # enter and leave the label on one axis. It keeps the x it comes in on when
  # that lies in the column, or else the x it goes on at; any other step is
  # in a gap, in sight.
  defp corner(%{lanes: lanes, label: {lx, _ly, w, _h}} = route) do
    {low, high} = {lx + min(@corner_pad, w / 2), lx + w - min(@corner_pad, w / 2)}
    within? = &(&1 >= low - 0.5 and &1 <= high + 0.5)

    lanes =
      [nil | lanes]
      |> Enum.zip(lanes)
      |> Enum.zip(tl(lanes) ++ [nil])
      |> Enum.map(fn
        {{{_r0, _t0, {a, _}, _k0}, {rank, {_l, top}, {_l2, bottom}, :over}},
         {_r2, {c, _}, _b2, _k2}} ->
          x =
            cond do
              within?.(a) -> a
              within?.(c) -> c
              true -> a |> max(low) |> min(high)
            end

          {rank, {x, top}, {x, bottom}, :over}

        {{_prev, piece}, _next} ->
          piece
      end)

    %{route | lanes: lanes}
  end

  defp corner(route), do: route

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
      # Tracks stay clear of the stubs at both ends of the gap.
      {_top, band_bottom} = Map.fetch!(bands, rank)
      {band_top, _bottom} = Map.fetch!(bands, rank + 1)
      {gap_top, gap_bottom} = {band_bottom + @arrow_stub, band_top - @arrow_stub}

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
