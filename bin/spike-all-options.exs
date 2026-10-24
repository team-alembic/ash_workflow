# Run: MIX_ENV=test direnv exec .. mix run bin/spike-all-options.exs
# Lays out every scenario with every combination of Svg options (direction,
# edges, labels, undo, undo_text) and lists the hard-rule failures.
alias AshWorkflow.Charts.Layered.Metrics
alias AshWorkflow.Charts.Svg

combos =
  for direction <- [:down, :right],
      edges <- [:orthogonal, :curved],
      labels <- [:beside, :over],
      undo <- [:marker, :lanes],
      undo_text <- [:label, :tag],
      do: [direction: direction, edges: edges, labels: labels, undo: undo, undo_text: undo_text]

scenarios = AshWorkflowTest.LayoutScenarios.all()

bad =
  for {name, graph} <- scenarios,
      opts <- combos,
      {result, _edges, _opts} = Svg.drawn_layout(graph, opts),
      (failures = result |> Metrics.scorecard() |> Metrics.hard_failures()) != [],
      do: "#{name} #{inspect(opts)}: #{Enum.join(failures, ", ")}"

IO.puts("#{length(bad)} failing of #{length(scenarios) * length(combos)}")
Enum.each(bad, &IO.puts/1)
