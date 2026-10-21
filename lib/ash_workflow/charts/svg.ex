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
  @label_max 260
  @start :__start__

  @impl true
  def file_extension, do: "svg"

  @impl true
  def render(%Graph{} = graph, opts) do
    opts = Keyword.validate!(opts, theme: :light)
    theme = opts[:theme]
    {result, edges} = layout(graph)
    colours = Palette.colours(theme)
    text = Palette.edge_label_colour(theme)

    [
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="#{num(result.width)}" height="#{num(result.height)}" ),
      ~s(viewBox="0 0 #{num(result.width)} #{num(result.height)}" font-family="#{TextWidth.font_family()}" font-size="#{@font_size}">\n),
      ~s(<rect width="100%" height="100%" fill="#{Palette.background(theme)}"/>\n),
      markers(colours, text),
      edges
      |> Enum.sort()
      |> Enum.map(fn {id, edge} -> edge_svg(edge, result.edges[id], colours, text) end),
      start_edge_svg(result.edges[0], text),
      graph.nodes |> Enum.map(&node_svg(&1, graph, result.nodes[&1.id], colours, text)),
      start_svg(result.nodes[@start], text),
      "</svg>\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc false
  # The layout and the graph edges by layout edge id, for the comparison script.
  def layout(%Graph{} = graph) do
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

          %Layered.Node{
            id: node.id,
            width: Float.ceil(width + 2 * @pad_x),
            height: length(lines) * @line_height + 2 * @pad_y
          }
        end)

    edges = graph.edges |> Enum.with_index(1) |> Map.new(fn {edge, i} -> {i, edge} end)

    layered_edges =
      [%Layered.Edge{id: 0, from: @start, to: initial.id}] ++
        for {id, edge} <- Enum.sort(edges) do
          lines = label_lines(edge)
          width = lines |> Enum.map(&TextWidth.width(&1, @font_size)) |> Enum.max()

          %Layered.Edge{
            id: id,
            from: edge.from,
            to: edge.to,
            label_width: Float.ceil(width + 8),
            label_height: length(lines) * @line_height
          }
        end

    {Layered.layout(nodes, layered_edges), edges}
  end

  @doc false
  # Pairs of boxes that overlap, as {a, b}: node boxes and label boxes.
  def overlaps(%Layered.Result{} = result) do
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

  defp node_lines(%{kind: :terminal} = node), do: [to_string(node.id) | note_lines(node)]
  defp node_lines(node), do: [to_string(node.id), Format.kind_text(node.kind) | note_lines(node)]

  defp note_lines(node), do: Enum.map(node.notes, &Format.note_text/1)

  defp label_lines(edge), do: TextWidth.wrap(Format.edge_text(edge), @label_max, @font_size)

  defp markers(colours, text) do
    for {class, colour} <- [transition: text] ++ edge_strokes(colours) do
      ~s(<marker id="arrow-#{class}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#{colour}"/></marker>\n)
    end
    |> then(&["<defs>\n", &1, "</defs>\n"])
  end

  defp edge_strokes(colours),
    do:
      for(
        class <- [:on_success, :on_error, :timeout, :undo],
        do: {class, colours[class][:stroke]}
      )

  defp edge_svg(edge, route, colours, text) do
    colour = if edge.kind == :transition, do: text, else: colours[edge.kind][:stroke]

    [
      ~s(<path d="#{path(route.points)}" fill="none" stroke="#{colour}" stroke-width="#{stroke_width(edge.kind)}" ),
      dash(edge.kind),
      ~s|stroke-linejoin="round" marker-end="url(#arrow-#{edge.kind})"/>\n|,
      label_svg(route.label, label_lines(edge), text)
    ]
  end

  # The edge from the start circle to the initial step has no Graph.Edge.
  defp start_edge_svg(route, text),
    do:
      ~s|<path d="#{path(route.points)}" fill="none" stroke="#{text}" stroke-width="1.5" marker-end="url(#arrow-transition)"/>\n|

  defp path([{x0, y0} | rest]),
    do: ["M#{num(x0)},#{num(y0)}" | Enum.map(rest, fn {x, y} -> " L#{num(x)},#{num(y)}" end)]

  defp stroke_width(:on_success), do: "2.5"
  defp stroke_width(_kind), do: "1.5"

  defp dash(:timeout), do: ~s(stroke-dasharray="6 4" )
  defp dash(:undo), do: ~s(stroke-dasharray="2 4" )
  defp dash(_kind), do: ""

  defp label_svg(nil, _lines, _text), do: []

  defp label_svg({x, y, _w, h}, lines, text) do
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
