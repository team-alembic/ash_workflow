# Run: MIX_ENV=test direnv exec .. mix run bin/spike-compare.exs
alias AshWorkflow.Charts
alias AshWorkflow.Charts.Svg

examples = [
  BasicWorkflow.DocumentApproval,
  BasicWorkflow.Incident,
  BasicWorkflow.Subscription,
  BasicWorkflow.ScheduledPost
]

dir = "tmp/spike"
File.mkdir_p!(dir)

engines = [
  native: fn resource, theme -> Charts.render(resource, Svg, theme: theme) end
]

rows =
  for resource <- examples, theme <- [:light, :dark] do
    name = resource |> Module.split() |> List.last() |> Macro.underscore()

    files =
      for {engine, draw} <- engines do
        file = "#{name}-#{theme}-#{engine}.svg"

        try do
          File.write!(Path.join(dir, file), draw.(resource, theme))
          {engine, file}
        rescue
          error -> IO.puts("#{engine} failed for #{name}: #{Exception.message(error)}") && {engine, nil}
        end
      end

    graph = Charts.graph(resource)
    {result, _edges} = Svg.layout(graph)

    times =
      for _ <- 1..20 do
        {us, _} = :timer.tc(fn -> Charts.render(resource, Svg, theme: theme) end)
        us
      end

    median_ms = (times |> Enum.sort() |> Enum.at(10)) / 1000

    %{
      name: name,
      theme: theme,
      files: files,
      nodes: length(graph.nodes),
      edges: length(graph.edges),
      crossings: result.crossings,
      overlaps: length(Svg.overlaps(result)),
      size: "#{round(result.width)}x#{round(result.height)}",
      ms: median_ms
    }
  end

IO.puts("| workflow | theme | nodes | edges | crossings | overlaps | size | median ms |")
IO.puts("|---|---|---|---|---|---|---|---|")

for r <- rows do
  IO.puts("| #{r.name} | #{r.theme} | #{r.nodes} | #{r.edges} | #{r.crossings} | #{r.overlaps} | #{r.size} | #{r.ms} |")
end

cells = fn r ->
  for {engine, file} <- r.files do
    img = if file, do: ~s(<img src="#{file}" style="max-width:100%">), else: "failed"
    ~s(<td style="vertical-align:top"><b>#{engine}</b><br>#{img}</td>)
  end
end

html = """
<!doctype html><meta charset="utf-8"><title>Native SVG spike</title>
<body style="font-family:sans-serif">
#{for r <- rows, do: "<h2>#{r.name} (#{r.theme})</h2><table><tr>#{cells.(r)}</tr></table>\n"}
</body>
"""

File.write!(Path.join(dir, "index.html"), html)
IO.puts("Wrote #{dir}/index.html")
