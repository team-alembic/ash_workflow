# Run: MIX_ENV=test direnv exec .. mix run bin/spike-undo-variants.exs [label]
# Draws the workflows that have undo in each way undo can be shown (marker
# or lanes, its text on the label or in a short tag), side by side, so a
# reader can choose. SPIKE_LABELS="beside" draws labels beside their edges;
# the default is over.
alias AshWorkflow.Charts
alias AshWorkflow.Charts.Layered.Metrics
alias AshWorkflow.Charts.Svg

dir = "tmp/spike/undo"
File.mkdir_p!(dir)
label = List.first(System.argv(), "run")

scenarios =
  [
    {"incident", Charts.graph(BasicWorkflow.Incident)},
    {"undo_workflow", Charts.graph(AshWorkflowTest.UndoWorkflow)}
  ] ++ Enum.filter(AshWorkflowTest.LayoutScenarios.probes(), &(elem(&1, 0) == "probe_undo_chain"))

undos = [
  marker: "no line, a hollow arrowhead at the start of the move",
  lanes: "a dotted line in its own lane"
]

labels = System.get_env("SPIKE_LABELS", "over") |> String.to_atom()
variants = for {undo, text} <- undos, undo_text <- [:label, :tag], do: {undo, undo_text, text}

modes = for direction <- [:down, :right], edges <- [:orthogonal, :curved], do: {direction, edges}

sections =
  for {name, graph} <- scenarios, {direction, edges} <- modes do
    cells =
      for {undo, undo_text, text} <- variants do
        file = "#{name}-#{direction}-#{edges}-#{undo}-#{undo_text}-#{labels}.svg"
        opts = [direction: direction, edges: edges, undo: undo, undo_text: undo_text, labels: labels]
        File.write!(Path.join(dir, file), Svg.render_graph(graph, opts))
        {result, _edges, _opts} = Svg.drawn_layout(graph, opts)
        failures = result |> Metrics.scorecard() |> Metrics.hard_failures()
        note = if failures == [], do: "", else: " ⚠ " <> Enum.join(failures, ", ")

        ~s(<td style="vertical-align:top;padding:8px"><div><b>undo #{undo}, text on #{undo_text}</b>: #{text}#{note}</div>) <>
          ~s(<img src="#{file}?v=#{label}" style="max-width:360px"></td>)
      end

    "<h2>#{name}, #{direction} / #{edges}</h2><table><tr>#{Enum.join(cells)}</tr></table>\n"
  end

File.write!(Path.join(dir, "index.html"), """
<!doctype html><meta charset="utf-8"><title>Undo variants</title>
<body style="font-family:sans-serif">
<h1>Undo: marker or lanes, text on the label or in a tag; labels #{labels} (#{label})</h1>
#{sections}
</body>
""")

IO.puts("Wrote #{dir}/index.html")
