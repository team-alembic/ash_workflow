# Run: MIX_ENV=test direnv exec .. mix run bin/spike-undo-variants.exs [label]
# Draws the workflows that have undo in each way undo can be shown, with
# labels beside and over their edges, side by side, so a reader can choose.
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

variants = for {undo, text} <- undos, labels <- [:beside, :over], do: {undo, labels, text}

modes = [{:down, :orthogonal}, {:down, :curved}, {:right, :orthogonal}, {:right, :curved}]

sections =
  for {name, graph} <- scenarios, {direction, edges} <- modes do
    cells =
      for {undo, labels, text} <- variants do
        file = "#{name}-#{direction}-#{edges}-#{undo}-#{labels}.svg"
        opts = [direction: direction, edges: edges, undo: undo, labels: labels]
        File.write!(Path.join(dir, file), Svg.render_graph(graph, opts))
        {result, _edges, _opts} = Svg.drawn_layout(graph, opts)
        failures = result |> Metrics.scorecard() |> Metrics.hard_failures()
        note = if failures == [], do: "", else: " ⚠ " <> Enum.join(failures, ", ")

        ~s(<td style="vertical-align:top;padding:8px"><div><b>undo #{undo}, labels #{labels}</b>: #{text}#{note}</div>) <>
          ~s(<img src="#{file}?v=#{label}" style="max-width:360px"></td>)
      end

    "<h2>#{name}, #{direction} / #{edges}</h2><table><tr>#{Enum.join(cells)}</tr></table>\n"
  end

File.write!(Path.join(dir, "index.html"), """
<!doctype html><meta charset="utf-8"><title>Undo and labels</title>
<body style="font-family:sans-serif">
<h1>Undo (marker, lanes) and labels (beside, over) (#{label})</h1>
#{sections}
</body>
""")

IO.puts("Wrote #{dir}/index.html")
