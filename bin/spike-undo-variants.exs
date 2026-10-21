# Run: MIX_ENV=test direnv exec .. mix run bin/spike-undo-variants.exs [label]
# Draws the workflows that have undo in each way undo can be shown, side by
# side, so a reader can choose.
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

variants = [
  marker: "No line: a hollow arrowhead at the start of the move",
  lanes: "A dotted line in its own lane, 24 px or more beside the move"
]

modes = [{:down, :orthogonal}, {:down, :curved}, {:right, :orthogonal}]

sections =
  for {name, graph} <- scenarios, {direction, edges} <- modes do
    cells =
      for {undo, text} <- variants do
        file = "#{name}-#{direction}-#{edges}-#{undo}.svg"
        File.write!(Path.join(dir, file), Svg.render_graph(graph, direction: direction, edges: edges, undo: undo))
        {result, _edges, _opts} = Svg.drawn_layout(graph, direction: direction, edges: edges, undo: undo)
        failures = result |> Metrics.scorecard() |> Metrics.hard_failures()
        note = if failures == [], do: "", else: " ⚠ " <> Enum.join(failures, ", ")

        ~s(<td style="vertical-align:top;padding:8px"><div><b>#{undo}</b>: #{text}#{note}</div>) <>
          ~s(<img src="#{file}?v=#{label}" style="max-width:440px"></td>)
      end

    "<h2>#{name}, #{direction} / #{edges}</h2><table><tr>#{Enum.join(cells)}</tr></table>\n"
  end

File.write!(Path.join(dir, "index.html"), """
<!doctype html><meta charset="utf-8"><title>Undo: three ways</title>
<body style="font-family:sans-serif">
<h1>Undo: three ways to draw it (#{label})</h1>
#{sections}
</body>
""")

IO.puts("Wrote #{dir}/index.html")
