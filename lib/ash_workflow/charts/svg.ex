defmodule AshWorkflow.Charts.Svg do
  @moduledoc false
  # Spike: draws an AshWorkflow.Charts.Graph as SVG with the pure Elixir
  # layered layout. Use it as a custom backend:
  #
  #     AshWorkflow.Charts.render(MyApp.Candidate, AshWorkflow.Charts.Svg, theme: :dark)

  @behaviour AshWorkflow.Charts.Backend

  alias AshWorkflow.Charts.Format
  alias AshWorkflow.Charts.Graph
  alias AshWorkflow.Charts.Layered
  alias AshWorkflow.Charts.Palette
  alias AshWorkflow.Charts.TextWidth

  @font_size 14
  @line_height 18
  @pad_x 12
  @pad_y 8
  @label_max 180
  @label_max_right 140
  @tag_size 11
  @tag_height 14
  @start :__start__

  @impl true
  def file_extension, do: "svg"

  @impl true
  def render(%Graph{} = graph, opts), do: render_graph(graph, opts)

  @doc false
  # Draws any Graph, also one built by hand. `layout:` is a keyword list for
  # Layered.layout/3, so a gallery run can try stage options.
  def render_graph(%Graph{} = graph, opts) do
    {result, edges, opts} = drawn_layout(graph, opts)
    theme = opts[:theme]
    marked = if opts[:undo] == :marker, do: edges_with_undo(graph), else: MapSet.new()

    labels = label_text(edges, label_max(opts[:direction]), opts[:undo_text])
    colours = Palette.colours(theme)
    text = Palette.edge_label_colour(theme)

    [
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="#{num(result.width)}" height="#{num(result.height)}" ),
      ~s(viewBox="0 0 #{num(result.width)} #{num(result.height)}" font-family="#{TextWidth.font_family()}" font-size="#{@font_size}">\n),
      ~s(<rect width="100%" height="100%" fill="#{Palette.background(theme)}"/>\n),
      markers(colours, text, Palette.background(theme), colours[:undo][:stroke]),
      edges
      |> Enum.sort()
      |> Enum.filter(fn {id, _edge} -> Map.has_key?(result.edges, id) end)
      |> Enum.map(fn {id, edge} ->
        edge_svg(
          edge,
          result.edges[id],
          Map.get(labels, id, []),
          colours,
          text,
          {result.routing, result.direction},
          MapSet.member?(marked, id),
          {opts[:labels], Palette.background(theme)}
        )
      end),
      start_edge_svg(result.edges[0], text, {result.routing, result.direction}),
      for {_id, %{tag: {lx, ly, w, h}, tag_text: tag} = route} <- Enum.sort(result.edges) do
        [
          if(route.tag_over,
            do:
              ~s(<rect x="#{num(lx)}" y="#{num(ly - h / 2)}" width="#{num(w)}" height="#{num(h)}" rx="3" fill="#{Palette.background(theme)}"/>\n),
            else: []
          ),
          ~s(<text x="#{num(lx + 2)}" y="#{num(ly)}" dominant-baseline="central" font-size="#{@tag_size}" fill="#{colours[:undo][:stroke]}">#{escape(tag)}</text>\n)
        ]
      end,
      graph.nodes |> Enum.map(&node_svg(&1, graph, result.nodes[&1.id], colours, text)),
      start_svg(result.nodes[@start], text),
      "</svg>\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc false
  # The layout exactly as render_graph/2 draws it, with the options it uses,
  # so the gallery scores what a reader sees.
  #
  # undo: :marker draws no undo line: the move it rewinds gets a hollow
  # arrowhead at its start. :lanes draws a dotted return line in its own lane.
  def drawn_layout(%Graph{} = graph, opts) do
    opts =
      Keyword.validate!(opts,
        theme: :light,
        direction: :down,
        edges: :orthogonal,
        undo: :marker,
        labels: :beside,
        undo_text: :label,
        layout: []
      )

    companions = if opts[:undo] == :lanes, do: :lanes, else: :none

    layout_opts =
      [
        direction: opts[:direction],
        routing: routing(opts[:edges]),
        companions: companions,
        labels: opts[:labels],
        undo_text: opts[:undo_text]
      ] ++ opts[:layout]

    {result, edges} = layout(graph, layout_opts)
    dropped = if opts[:undo] == :marker, do: Map.keys(partners(edges)), else: []
    result = %{result | edges: Map.drop(result.edges, dropped)}
    result = if opts[:undo_text] == :tag, do: place_tags(result, edges, opts), else: result
    {result, edges, opts}
  end

  # undo_text: :tag puts the undo window as a short tag, such as "↶ 1h",
  # beside the end the undo returns to: the hollow marker, or the arrowhead
  # of the undo line. It takes the first free place beside the line, nearest
  # the box.
  defp place_tags(result, edges, opts) do
    edges
    |> partners()
    |> Enum.sort()
    |> Enum.reduce(result, fn {undo, partner}, result ->
      with text when is_binary(text) <- short_window(Map.fetch!(edges, undo).label),
           {id, [_p, _q | _] = points} <- tag_anchor(result, undo, partner, opts[:undo]) do
        {box, over?} = tag_box(result, id, points, text, opts[:direction])

        %{
          result
          | edges:
              Map.update!(
                result.edges,
                id,
                &Map.merge(&1, %{tag: box, tag_text: text, tag_over: over?})
              )
        }
      else
        _none -> result
      end
    end)
  end

  defp short_window(label) do
    case Regex.run(~r/within (\d+) (\w)/u, label) do
      [_, n, unit] -> "↶ #{n}#{unit}"
      nil -> nil
    end
  end

  defp tag_anchor(result, _undo, partner, :marker) do
    case result.edges[partner] do
      %{points: points} -> {partner, points}
      nil -> nil
    end
  end

  defp tag_anchor(result, undo, _partner, :lanes) do
    case result.edges[undo] do
      %{points: points} -> {undo, Enum.reverse(points)}
      nil -> nil
    end
  end

  defp tag_box(result, id, [{px, py}, {qx, qy} | _] = points, text, direction) do
    w = Float.ceil(TextWidth.width(text, @tag_size) + 4)
    h = @tag_height

    # Beside the line on either side, first just outside the box, then
    # further along the edge, where crowded edges have spread apart.
    corners =
      for k <- 0..9, gap <- [4, 20], side <- [1, -1] do
        along = 3 + k * (h + 2)

        if direction == :right do
          x = if qx >= px, do: px + along, else: px - along - w
          {x, if(side > 0, do: py - gap - h, else: py + gap)}
        else
          y = if qy >= py, do: py + along, else: py - along - h
          {if(side > 0, do: px + gap, else: px - gap - w), y}
        end
      end

    # If no place beside it is free, the tag sits over its own line, as a
    # label drawn over its edge does.
    over =
      for {{ax, ay}, {bx, by}} <- Enum.zip(points, tl(points)),
          do: {(ax + bx) / 2 - w / 2, (ay + by) / 2 - h / 2}

    case Enum.find(corners, &tag_free?(result, &1, w, h, nil)) do
      {left, top} ->
        {{left, top + h / 2, w, h}, false}

      nil ->
        {left, top} = Enum.find(over, hd(corners), &tag_free?(result, &1, w, h, id))
        {{left, top + h / 2, w, h}, true}
    end
  end

  # Free of every step, label, tag and edge line, except the line of edge
  # `own` when the tag sits over it.
  defp tag_free?(result, {left, top}, w, h, own) do
    box = {left, top, left + w, top + h}

    boxes =
      Enum.map(result.nodes, fn {_id, {x, y, bw, bh}} -> {x - bw / 2, y - bh / 2, bw, bh} end) ++
        for({_id, %{label: {lx, ly, lw, lh}}} <- result.edges, do: {lx, ly - lh / 2, lw, lh}) ++
        for {_id, %{tag: {lx, ly, lw, lh}}} <- result.edges, do: {lx, ly - lh / 2, lw, lh}

    not Enum.any?(result.edges, fn {id, %{points: points}} ->
      id != own and
        Layered.Metrics.enters?(points, box)
    end) and
      not Enum.any?(boxes, fn {bx, by, bw, bh} ->
        bx < left + w and left < bx + bw and by < top + h and top < by + bh
      end)
  end

  defp routing(:polyline), do: :polyline
  defp routing(:curved), do: :spline
  defp routing(:orthogonal), do: :orthogonal

  @doc false
  # The layout and the graph edges by layout edge id. `opts` go to
  # Layered.layout/3.
  def layout(%Graph{} = graph, opts \\ []) do
    {nodes, layered_edges, edges} =
      layered_input(
        graph,
        Keyword.get(opts, :direction, :down),
        Keyword.get(opts, :undo_text, :label)
      )

    {Layered.layout(nodes, layered_edges, opts), edges}
  end

  @doc false
  # The engine's input: the boxes for the start circle, the steps and the edge
  # labels, and the graph edges by layout edge id.
  def layered_input(%Graph{} = graph, direction \\ :down, undo_text \\ :label) do
    initial = Enum.find(graph.nodes, & &1.initial?)

    nodes =
      [%Layered.Node{id: @start, width: 14, height: 14}] ++
        Enum.map(graph.nodes, fn node ->
          [name | rest] = node_lines(node)
          lines = [name | rest]

          width =
            [
              TextWidth.width(name, @font_size) * TextWidth.bold_factor()
              | Enum.map(rest, &TextWidth.width(&1, @font_size))
            ]
            |> Enum.max()

          # Long enough on the sides that carry ports: 16 px apart and 6 px
          # from each corner. Those are the top and bottom sides going down,
          # and the left and right sides going right.
          ports = max(degree(graph, node.id, :from), degree(graph, node.id, :to))
          room = (ports - 1) * 16 + 2 * 6
          width = width + 2 * @pad_x
          height = length(lines) * @line_height + 2 * @pad_y

          {width, height} =
            if direction == :right,
              do: {width, max(height, room)},
              else: {max(width, room), height}

          %Layered.Node{id: node.id, width: Float.ceil(width * 1.0), height: height}
        end)

    edges = graph.edges |> Enum.with_index(1) |> Map.new(fn {edge, i} -> {i, edge} end)
    partners = partners(edges)
    labels = label_text(edges, label_max(direction), undo_text)

    layered_edges =
      [%Layered.Edge{id: 0, from: @start, to: initial.id}] ++
        for {id, edge} <- Enum.sort(edges) do
          case {Map.fetch(partners, id), Map.get(labels, id, [])} do
            # An undo edge with a forward partner gets its own lane but no
            # label: its text is in the partner's label.
            {{:ok, partner}, _lines} ->
              %Layered.Edge{id: id, from: edge.from, to: edge.to, companion: partner}

            {:error, lines} ->
              width = lines |> Enum.map(&TextWidth.width(&1, @font_size)) |> Enum.max()

              %Layered.Edge{
                id: id,
                from: edge.from,
                to: edge.to,
                label_width: Float.ceil(width + 8),
                label_height: length(lines) * @line_height
              }
          end
        end

    {nodes, layered_edges, edges}
  end

  @doc false
  # Pairs of boxes that overlap, as {a, b}: node boxes and label boxes.
  def overlaps(%Layered.Result{} = result), do: Layered.Metrics.overlaps(result)

  defp node_lines(%{kind: :terminal} = node), do: [to_string(node.id) | note_lines(node)]
  defp node_lines(node), do: [to_string(node.id), Format.kind_text(node.kind) | note_lines(node)]

  defp note_lines(node), do: Enum.map(node.notes, &Format.note_text/1)

  # Edges that leave (:from) or enter (:to) a step, not counting self-loops
  # or the undo edges that are drawn as markers.
  defp degree(graph, id, side) do
    other = if side == :from, do: :to, else: :from

    undo =
      graph.edges
      |> Enum.with_index(1)
      |> Map.new(fn {e, i} -> {i, e} end)
      |> partners()
      |> Map.keys()
      |> MapSet.new()

    graph.edges
    |> Enum.with_index(1)
    |> Enum.count(fn {e, i} ->
      Map.fetch!(e, side) == id and Map.fetch!(e, other) != id and not MapSet.member?(undo, i)
    end)
    |> Kernel.+(
      if side == :to and Enum.any?(graph.nodes, &(&1.id == id and &1.initial?)), do: 1, else: 0
    )
  end

  # Labels wrap narrower in the right direction, where each label's width adds
  # to the chart's length.
  defp label_max(:right), do: @label_max_right
  defp label_max(_down), do: @label_max

  # A leading symbol (⚙, ✖, ⏱, ↶) stays on the line of the word after it: a
  # no-break space joins them, so wrapping never leaves a symbol alone.
  defp label_lines(edge, max) do
    edge
    |> Format.edge_text()
    |> String.replace(~r/^(\S) /u, "\\1\u00A0")
    |> TextWidth.wrap(max, @font_size)
  end

  # %{undo edge id => the forward edge it rewinds}. An undo edge with a
  # forward partner is drawn beside it, and its text joins the partner's
  # label, so one move and its undo read as one thing.
  defp partners(edges) do
    for {id, %{kind: :undo} = undo} <- edges,
        undo.from != undo.to,
        partner =
          edges
          |> Enum.sort()
          |> Enum.find_value(fn {pid, e} ->
            e.kind != :undo and e.from == undo.to and e.to == undo.from and pid
          end),
        partner,
        into: %{},
        do: {id, partner}
  end

  # %{edge id => label lines}. A forward edge with an undo partner gets the
  # undo's text as its last line; the undo edge itself has no label.
  # With undo_text: :tag the undo's text goes in a tag instead.
  defp label_text(edges, max, undo_text) do
    partners = partners(edges)

    undo_of =
      if undo_text == :tag,
        do: %{},
        else: Map.new(partners, fn {undo, partner} -> {partner, undo} end)

    for {id, edge} <- edges, not Map.has_key?(partners, id), into: %{} do
      extra =
        case Map.fetch(undo_of, id) do
          {:ok, undo} -> label_lines(Map.fetch!(edges, undo), max)
          :error -> []
        end

      {id, label_lines(edge, max) ++ extra}
    end
  end

  # An arrowhead per edge colour, all 10 px long and 9 px wide whatever the
  # line width: markerUnits="userSpaceOnUse" stops a thick on_success line
  # from drawing a big arrowhead.
  defp markers(colours, text, background, undo) do
    arrows =
      for {class, colour} <- [transition: text] ++ edge_strokes(colours) do
        ~s(<marker id="arrow-#{class}" viewBox="0 0 10 9" refX="9" refY="4.5" markerWidth="10" markerHeight="9" markerUnits="userSpaceOnUse" orient="auto-start-reverse"><path d="M0,0 L10,4.5 L0,9 z" fill="#{colour}"/></marker>\n)
      end

    # A hollow arrowhead at the start of a move that undo can rewind.
    hollow =
      ~s(<marker id="undo-start" viewBox="-1 -1 12 11" refX="9" refY="4.5" markerWidth="12" markerHeight="11" markerUnits="userSpaceOnUse" orient="auto-start-reverse"><path d="M0,0 L10,4.5 L0,9 z" fill="#{background}" stroke="#{undo}" stroke-width="1.5"/></marker>\n)

    ["<defs>\n", arrows, hollow, "</defs>\n"]
  end

  # The ids of the forward edges that an undo edge rewinds.
  defp edges_with_undo(graph) do
    graph.edges
    |> Enum.with_index(1)
    |> Map.new(fn {e, i} -> {i, e} end)
    |> partners()
    |> Map.values()
    |> MapSet.new()
  end

  defp edge_strokes(colours),
    do:
      for(
        class <- [:on_success, :on_error, :timeout, :undo],
        do: {class, colours[class][:stroke]}
      )

  defp edge_svg(edge, route, lines, colours, text, {routing, direction}, marked?, labels) do
    colour = if edge.kind == :transition, do: text, else: colours[edge.kind][:stroke]

    [
      ~s(<path d="#{draw_route(route, routing, direction)}" fill="none" stroke="#{colour}" stroke-width="#{stroke_width(edge.kind)}" ),
      dash(edge.kind),
      if(marked?, do: ~s|marker-start="url(#undo-start)" |, else: ""),
      ~s|stroke-linejoin="round" marker-end="url(#arrow-#{edge.kind})"/>\n|,
      label_svg(route.label, lines, text, labels)
    ]
  end

  # The edge from the start circle to the initial step has no Graph.Edge.
  defp start_edge_svg(route, text, {routing, direction}),
    do:
      ~s|<path d="#{draw(route.points, routing, direction)}" fill="none" stroke="#{text}" stroke-width="1.5" marker-end="url(#arrow-transition)"/>\n|

  defp draw_route(%{curve: [first | _] = curve}, _routing, _direction) do
    xy = fn {x, y} -> "#{num(x)},#{num(y)}" end
    start = elem(first, 1)

    [
      "M#{xy.(start)}"
      | Enum.map(curve, fn
          {:line, _a, b} -> " L#{xy.(b)}"
          {:cubic, _a, c1, c2, b} -> " C#{xy.(c1)} #{xy.(c2)} #{xy.(b)}"
        end)
    ]
  end

  defp draw_route(route, routing, direction), do: draw(route.points, routing, direction)

  defp draw(points, :spline, direction), do: curve(points, direction)
  defp draw(points, :orthogonal, _direction), do: rounded(points)
  defp draw(points, _polyline, _direction), do: path(points)

  # A vertical segment stays straight: it is a lane through a band, beside a
  # label or a box. Any other segment is a gap crossing, drawn as a cubic
  # curve that leaves and arrives vertically. So the curve joins its lanes
  # without a kink, never swings wider than its two ends, and cannot bulge
  # into a label beside a lane.
  defp curve([{x0, y0} | _] = points, :right) do
    # The same curve, mirrored on the diagonal: lanes are horizontal.
    [{y0, x0} | Enum.map(tl(points), fn {x, y} -> {y, x} end)]
    |> curve_segments()
    |> Enum.map(fn {kind, coords} -> {kind, Enum.map(coords, fn {a, b} -> {b, a} end)} end)
    |> curve_path({x0, y0})
  end

  defp curve([{x0, y0} | _] = points, _down) do
    points |> curve_segments() |> curve_path({x0, y0})
  end

  defp curve_segments(points) do
    points
    |> Enum.zip(tl(points))
    |> Enum.map(fn
      {{x1, _y1}, {x2, y2}} when abs(x1 - x2) < 0.5 ->
        {:line, [{x2, y2}]}

      {{x1, y1}, {x2, y2}} ->
        # Long vertical tangents make a deep S: the edge leaves and arrives
        # straight, and swings in the middle of the gap.
        reach = (y2 - y1) * 0.9
        {:cubic, [{x1, y1 + reach}, {x2, y2 - reach}, {x2, y2}]}
    end)
  end

  defp curve_path(segments, {x0, y0}) do
    [
      "M#{num(x0)},#{num(y0)}"
      | Enum.map(segments, fn
          {:line, [{x, y}]} ->
            " L#{num(x)},#{num(y)}"

          {:cubic, coords} ->
            " C" <> Enum.map_join(coords, " ", fn {x, y} -> "#{num(x)},#{num(y)}" end)
        end)
    ]
  end

  # Straight segments with each corner cut by a quadratic curve of radius 6,
  # or less on a short segment.
  defp rounded([{x0, y0} | _] = points) do
    corners =
      points
      |> Enum.chunk_every(3, 1, :discard)
      |> Enum.map(fn [{px, py}, {qx, qy}, {rx, ry}] ->
        l1 = :math.sqrt((qx - px) ** 2 + (qy - py) ** 2)
        l2 = :math.sqrt((rx - qx) ** 2 + (ry - qy) ** 2)

        if l1 == 0 or l2 == 0 do
          " L#{num(qx)},#{num(qy)}"
        else
          r = Enum.min([6, l1 / 2, l2 / 2])
          {ax, ay} = {qx - (qx - px) / l1 * r, qy - (qy - py) / l1 * r}
          {bx, by} = {qx + (rx - qx) / l2 * r, qy + (ry - qy) / l2 * r}
          " L#{num(ax)},#{num(ay)} Q#{num(qx)},#{num(qy)} #{num(bx)},#{num(by)}"
        end
      end)

    {xn, yn} = List.last(points)
    ["M#{num(x0)},#{num(y0)}", corners, " L#{num(xn)},#{num(yn)}"]
  end

  defp path([{x0, y0} | rest]),
    do: ["M#{num(x0)},#{num(y0)}" | Enum.map(rest, fn {x, y} -> " L#{num(x)},#{num(y)}" end)]

  defp stroke_width(:on_success), do: "2.5"
  defp stroke_width(_kind), do: "1.5"

  defp dash(:timeout), do: ~s(stroke-dasharray="6 4" )
  defp dash(:undo), do: ~s(stroke-dasharray="2 4" )
  defp dash(_kind), do: ""

  defp label_svg(nil, _lines, _text, _labels), do: []

  # A label over its edge hides the line behind it with the background
  # colour, and centres its text on the line.
  defp label_svg({x, y, w, h}, lines, text, {:over, background}) do
    top = y - h / 2 + @line_height / 2

    [
      ~s(<rect x="#{num(x)}" y="#{num(y - h / 2)}" width="#{num(w)}" height="#{num(h)}" rx="4" fill="#{background}"/>\n)
      | for {line, i} <- Enum.with_index(lines) do
          ~s(<text x="#{num(x + w / 2)}" y="#{num(top + i * @line_height)}" text-anchor="middle" dominant-baseline="central" fill="#{text}">#{escape(line)}</text>\n)
        end
    ]
  end

  defp label_svg({x, y, _w, h}, lines, text, _labels) do
    top = y - h / 2 + @line_height / 2

    for {line, i} <- Enum.with_index(lines) do
      ~s(<text x="#{num(x)}" y="#{num(top + i * @line_height)}" dominant-baseline="central" fill="#{text}">#{escape(line)}</text>\n)
    end
  end

  defp node_svg(node, graph, {x, y, w, h}, colours, text) do
    class = if node.kind == :terminal, do: Palette.terminal_class(node.id, graph), else: node.kind
    style = colours[class]
    fill_text = Keyword.get(style, :text, text)
    left = x - w / 2
    top = y - h / 2
    dash = if node.kind == :wait_state, do: ~s( stroke-dasharray="5 3"), else: ""

    [
      ~s(<rect x="#{num(left)}" y="#{num(top)}" width="#{num(w)}" height="#{num(h)}" rx="6" fill="#{style[:fill]}" stroke="#{style[:stroke]}" stroke-width="1.5"#{dash}/>\n),
      if(node.kind == :terminal,
        do:
          ~s(<rect x="#{num(left + 3)}" y="#{num(top + 3)}" width="#{num(w - 6)}" height="#{num(h - 6)}" rx="4" fill="none" stroke="#{style[:stroke]}" stroke-width="1"/>\n),
        else: []
      ),
      node
      |> node_lines()
      |> Enum.with_index()
      |> Enum.map(fn {line, i} ->
        weight = if i == 0, do: ~s( font-weight="bold"), else: ""

        ~s(<text x="#{num(x)}" y="#{num(top + @pad_y + @line_height / 2 + i * @line_height)}" text-anchor="middle" dominant-baseline="central" fill="#{fill_text}"#{weight}>#{escape(line)}</text>\n)
      end)
    ]
  end

  defp start_svg({x, y, _w, _h}, text),
    do: ~s(<circle cx="#{num(x)}" cy="#{num(y)}" r="7" fill="#{text}"/>\n)

  # Two decimals at most, and no trailing ".0", so the bytes are stable.
  defp num(value) when is_integer(value), do: Integer.to_string(value)

  defp num(value) do
    rounded = Float.round(value * 1.0, 2)

    if rounded == trunc(rounded),
      do: Integer.to_string(trunc(rounded)),
      else: Float.to_string(rounded)
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
