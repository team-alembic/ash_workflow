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

      sorted
      |> Enum.with_index()
      |> Enum.map(fn {{id, _other}, i} ->
        {{kind, id}, ((i + 1) / (k + 1) - 0.5) * w * @port_spread}
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
          do: {rank, {id, i}, min(x1, x2), max(x1, x2)}

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

  defp tracks(spans, bands) do
    spans
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.sort()
    |> Enum.flat_map(fn {rank, group} ->
      {placed, ends} =
        group
        |> Enum.sort_by(&{elem(&1, 2), elem(&1, 3), elem(&1, 1)})
        |> Enum.map_reduce([], fn {_rank, key, left, right}, ends ->
          case Enum.find_index(ends, &(&1 + @track_gap < left)) do
            nil -> {{key, length(ends)}, ends ++ [right]}
            t -> {{key, t}, List.replace_at(ends, t, right)}
          end
        end)

      k = length(ends)
      {_top, gap_top} = Map.fetch!(bands, rank)
      {gap_bottom, _bottom} = Map.fetch!(bands, rank + 1)

      Enum.map(placed, fn {key, t} ->
        {key, gap_top + (gap_bottom - gap_top) * (t + 1) / (k + 1)}
      end)
    end)
    |> Map.new()
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
