defmodule AshWorkflow.Charts.Layered.Metrics do
  @moduledoc false
  # The spike's scorecard for one layout. Hard keys must pass; soft keys are
  # compared with the previous gallery run to catch regressions. See the beauty
  # rubric in the plan for why each key is here.

  alias AshWorkflow.Charts.Layered.Result

  @end_radius 3
  @inset 2
  @max_label_distance 12

  def scorecard(%Result{} = result) do
    lines = Map.new(result.edges, fn {id, e} -> {id, e.points} end)

    # Bends, jogs and segments count the corners of polyline routes. A curve
    # or a return arc is sampled for the other checks, and its samples are
    # not corners, so it does not count here.
    shaped =
      for {id, e} <- result.edges,
          not Map.has_key?(e, :curve),
          not Map.has_key?(e, :arc),
          into: %{},
          do: {id, {e.points, Map.get(e, :label)}}

    widths =
      Enum.map(result.nodes, fn {_id, {_x, _y, w, h}} ->
        if result.direction == :right, do: h, else: w
      end)

    mean_width = Enum.sum(widths) / max(length(widths), 1)

    %{
      overlaps: length(overlaps(result)),
      edge_through_node: edge_through_node(result.nodes, lines),
      edge_through_label: edge_through_label(result.edges),
      label_distance: label_distance(result.edges),
      flow: flow(result, lines),
      crossings: crossings(lines),
      bends: shaped |> Map.values() |> Enum.map(&bends/1) |> Enum.sum(),
      segments: shaped |> Map.values() |> Enum.map(&visible_segments/1) |> Enum.sum(),
      arrow_room: arrow_room(result, lines),
      jogs: shaped |> Map.values() |> Enum.map(&jogs/1) |> Enum.sum(),
      lateral: Float.round(lateral(result.direction, lines) / mean_width, 2),
      area_ratio: Float.round(area_ratio(result), 2),
      aspect: Float.round(result.width / max(result.height, 1), 2)
    }
  end

  def hard_failures(card) do
    [
      card.overlaps > 0 && "overlaps #{card.overlaps}",
      card.edge_through_node > 0 && "edge_through_node #{card.edge_through_node}",
      card.edge_through_label > 0 && "edge_through_label #{card.edge_through_label}",
      card.label_distance > @max_label_distance && "label_distance #{card.label_distance}",
      card.arrow_room > 0 && "arrow_room #{card.arrow_room}",
      card.flow < 1.0 && "flow #{card.flow}"
    ]
    |> Enum.filter(& &1)
  end

  def overlaps(%Result{} = result) do
    boxes =
      Enum.map(result.nodes, fn {id, {x, y, w, h}} ->
        {{:node, id}, x - w / 2, y - h / 2, w, h}
      end) ++
        for {id, %{label: {lx, ly, w, h}}} <- result.edges,
            do: {{:label, id}, lx, ly - h / 2, w, h}

    for {a, ax, ay, aw, ah} <- boxes,
        {b, bx, by, bw, bh} <- boxes,
        a < b,
        ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah,
        do: {a, b}
  end

  # A segment crosses a node box, shrunk by 2 px, that does not hold either
  # end of its edge.
  defp edge_through_node(nodes, lines) do
    boxes =
      Map.new(nodes, fn {id, {x, y, w, h}} ->
        {id, {x - w / 2, y - h / 2, x + w / 2, y + h / 2}}
      end)

    lines
    |> Enum.map(fn {_id, points} ->
      ends = [hd(points), List.last(points)]

      own =
        for {id, box} <- boxes, Enum.any?(ends, &touches?(&1, box)), into: MapSet.new(), do: id

      for {id, {l, t, r, b}} <- boxes,
          not MapSet.member?(own, id),
          {p, q} <- segments(points),
          hits?(p, q, {l + @inset, t + @inset, r - @inset, b - @inset}),
          reduce: 0 do
        n -> n + 1
      end
    end)
    |> Enum.sum()
  end

  # A segment crosses another edge's label box, shrunk by 1 px. The checkpoint
  # 1 feedback named this as one of the two things that made charts rubbish.
  defp edge_through_label(edges) do
    labels =
      for {id, %{label: {lx, ly, w, h}}} <- edges,
          do: {id, {lx + 1, ly - h / 2 + 1, lx + w - 1, ly + h / 2 - 1}}

    # One count per edge and label pair, however many segments cross.
    for {id, %{points: points}} <- edges,
        {label_id, box} <- labels,
        label_id != id,
        Enum.any?(segments(points), fn {p, q} -> hits?(p, q, box) end),
        reduce: 0 do
      n -> n + 1
    end
  end

  defp touches?({x, y}, {l, t, r, b}),
    do:
      x >= l - @end_radius and x <= r + @end_radius and y >= t - @end_radius and
        y <= b + @end_radius

  # Liang–Barsky clipping: does the segment enter the box?
  defp hits?({x1, y1}, {x2, y2}, {left, top, right, bottom}) do
    dx = x2 - x1
    dy = y2 - y1
    checks = [{-dx, x1 - left}, {dx, right - x1}, {-dy, y1 - top}, {dy, bottom - y1}]

    result =
      Enum.reduce_while(checks, {0.0, 1.0}, fn {p, q}, {t0, t1} ->
        cond do
          p == 0 and q < 0 -> {:halt, nil}
          p == 0 -> {:cont, {t0, t1}}
          p < 0 -> {:cont, {max(t0, q / p), t1}}
          true -> {:cont, {t0, min(t1, q / p)}}
        end
      end)

    match?({t0, t1} when t0 < t1, result)
  end

  defp label_distance(edges) do
    edges
    |> Enum.flat_map(fn
      {_id, %{label: {lx, ly, w, h}, points: points}} ->
        box = {lx, ly - h / 2, lx + w, ly + h / 2}
        samples = for x <- [lx, lx + w / 2, lx + w], y <- [ly - h / 2, ly, ly + h / 2], do: {x, y}

        # A label drawn over its own edge is at distance 0.
        if Enum.any?(segments(points), fn {p, q} -> hits?(p, q, box) end),
          do: [0.0],
          else: [samples |> Enum.map(&distance_to_line(&1, points)) |> Enum.min()]

      _no_label ->
        []
    end)
    |> Enum.max(fn -> 0 end)
    |> Float.round(1)
  end

  defp distance_to_line(point, points),
    do: points |> segments() |> Enum.map(fn {a, b} -> distance(point, a, b) end) |> Enum.min()

  defp distance({px, py}, {ax, ay}, {bx, by}) do
    dx = bx - ax
    dy = by - ay
    length2 = dx * dx + dy * dy

    t =
      if length2 == 0,
        do: 0.0,
        else: max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length2))

    :math.sqrt((px - ax - t * dx) ** 2 + (py - ay - t * dy) ** 2)
  end

  defp flow(result, lines) do
    main = if result.direction == :right, do: 0, else: 1

    forward =
      for {id, points} <- lines,
          not MapSet.member?(result.reversed, id),
          hd(points) != List.last(points),
          do: elem(List.last(points), main) > elem(hd(points), main)

    if forward == [], do: 1.0, else: Enum.count(forward, & &1) / length(forward)
  end

  defp crossings(lines) do
    lines = lines |> Enum.sort() |> Enum.map(&elem(&1, 1))

    for {a, i} <- Enum.with_index(lines),
        {b, j} <- Enum.with_index(lines),
        i < j,
        crosses?(a, b),
        reduce: 0 do
      n -> n + 1
    end
  end

  defp crosses?(a, b) do
    ends = [hd(a), List.last(a), hd(b), List.last(b)]

    Enum.any?(segments(a), fn {p1, p2} ->
      Enum.any?(segments(b), fn {q1, q2} ->
        case intersection(p1, p2, q1, q2) do
          nil -> false
          point -> not Enum.any?(ends, &near?(&1, point))
        end
      end)
    end)
  end

  defp intersection({x1, y1}, {x2, y2}, {x3, y3}, {x4, y4}) do
    d = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)

    if abs(d) < 1.0e-9 do
      nil
    else
      t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / d
      u = ((x1 - x3) * (y1 - y2) - (y1 - y3) * (x1 - x2)) / d
      if t > 0 and t < 1 and u > 0 and u < 1, do: {x1 + t * (x2 - x1), y1 + t * (y2 - y1)}
    end
  end

  # The checkpoint 2 feedback: arrows that sit on a short or tilted last
  # segment look broken. An arrow needs a last segment in the main direction,
  # at least 12 px long. Counts the edges without one; self-loops enter from
  # the side and do not count.
  @arrow_room 20

  defp arrow_room(result, lines) do
    main = if result.direction == :right, do: 0, else: 1
    side = 1 - main

    Enum.count(lines, fn {id, points} ->
      not MapSet.member?(result.loops, id) and length(points) >= 2 and
        (fn [a, b] ->
           abs(elem(b, side) - elem(a, side)) >= 0.5 or
             abs(elem(b, main) - elem(a, main)) < @arrow_room
         end).(Enum.take(points, -2))
    end)
  end

  # Segments under 10 px: the small sideways steps the checkpoint 2 feedback
  # called avoidable deviations.
  defp jogs({points, label}) do
    points
    |> segments()
    |> Enum.reject(&hidden?(&1, label))
    |> Enum.count(fn {{x1, y1}, {x2, y2}} -> :math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2) < 10 end)
  end

  defp visible_segments({points, label}),
    do: points |> segments() |> Enum.reject(&hidden?(&1, label)) |> length()

  # A turn is an inner point where the route changes direction. A turn behind
  # the edge's own label, drawn over the edge, is not seen and does not count.
  defp bends({points, label}) do
    points
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.count(fn [{ax, ay}, {bx, by} = b, {cx, cy}] ->
      abs((bx - ax) * (cy - by) - (by - ay) * (cx - bx)) > 1.0e-6 and not inside?(b, label)
    end)
  end

  defp hidden?({a, b}, label), do: inside?(a, label) and inside?(b, label)

  defp inside?(_point, nil), do: false

  defp inside?({x, y}, {lx, ly, w, h}),
    do: x > lx and x < lx + w and y > ly - h / 2 and y < ly + h / 2

  defp lateral(direction, lines) do
    side = if direction == :right, do: 1, else: 0

    lines
    |> Map.values()
    |> Enum.map(fn points -> abs(elem(List.last(points), side) - elem(hd(points), side)) end)
    |> Enum.sum()
  end

  defp area_ratio(result) do
    boxes =
      Enum.map(result.nodes, fn {_id, {_x, _y, w, h}} -> w * h end) ++
        for {_id, %{label: {_lx, _ly, w, h}}} <- result.edges, do: w * h

    result.width * result.height / max(Enum.sum(boxes), 1)
  end

  defp segments(points), do: Enum.zip(points, tl(points))
  defp near?({x1, y1}, {x2, y2}), do: abs(x1 - x2) <= @end_radius and abs(y1 - y2) <= @end_radius
end
