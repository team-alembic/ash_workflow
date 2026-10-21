# Run: MIX_ENV=test direnv exec .. mix run bin/spike-gallery.exs [label]
# Draws every scenario in every mode, writes tmp/spike/gallery/, prints the
# scorecard, and compares it with the previous run.

alias AshWorkflow.Charts.Layered.Metrics
alias AshWorkflow.Charts.Svg
alias AshWorkflowTest.LayoutScenarios

# SPIKE_LABELS="over" draws each label over its own edge, in its own gallery.
labels = System.get_env("SPIKE_LABELS", "beside") |> String.to_atom()
dir = if labels == :beside, do: "tmp/spike/gallery", else: "tmp/spike/gallery-#{labels}"
File.mkdir_p!(dir)
label = List.first(System.argv(), "run")
previous_file = Path.join(dir, "scorecard.json")
previous = if File.exists?(previous_file), do: Jason.decode!(File.read!(previous_file)), else: %{}

# SPIKE_DIRECTIONS="down" limits the run to some directions, for a checkpoint.
directions =
  case System.get_env("SPIKE_DIRECTIONS") do
    nil -> [:down, :right]
    text -> text |> String.split(",", trim: true) |> Enum.map(&String.to_atom/1)
  end

modes = for direction <- directions, edges <- [:curved, :orthogonal], do: {direction, edges}
soft = [:crossings, :bends, :jogs, :segments, :lateral, :area_ratio]

# Stage options to try, for example SPIKE_LAYOUT="[ranker: :network_simplex]".
extra =
  case System.get_env("SPIKE_LAYOUT") do
    nil -> []
    text -> text |> Code.eval_string() |> elem(0)
  end

cards =
  for {name, graph} <- LayoutScenarios.all(), {direction, edges} <- modes, into: %{} do
    key = "#{name}-#{direction}-#{edges}"
    svg = Svg.render_graph(graph, direction: direction, edges: edges, labels: labels, layout: extra)
    File.write!(Path.join(dir, key <> ".svg"), svg)
    {result, _edges, _opts} = Svg.drawn_layout(graph, direction: direction, edges: edges, labels: labels, layout: extra)
    {key, Metrics.scorecard(result)}
  end

hard =
  cards
  |> Enum.sort()
  |> Enum.map(fn {key, card} -> {key, Metrics.hard_failures(card)} end)
  |> Enum.reject(fn {_key, failures} -> failures == [] end)

regressed? = fn was, new -> is_number(was) and new > was * 1.1 and new - was >= 1 end

regressions =
  for {key, card} <- Enum.sort(cards),
      Map.has_key?(previous, key),
      metric <- soft,
      regressed?.(previous[key][to_string(metric)], Map.fetch!(card, metric)),
      do: "#{key} #{metric}: #{previous[key][to_string(metric)]} -> #{Map.fetch!(card, metric)}"

IO.puts("## Gallery #{label}: #{map_size(cards)} charts")
IO.puts("\n### Hard failures (#{length(hard)})")
for {key, failures} <- hard, do: IO.puts("- #{key}: #{Enum.join(failures, ", ")}")
IO.puts("\n### Soft regressions against the previous run (#{length(regressions)})")
for line <- regressions, do: IO.puts("- " <> line)

for {direction, _edges} <- Enum.uniq_by(modes, &elem(&1, 0)) do
  mine = for {key, card} <- cards, String.contains?(key, "-#{direction}-"), do: card
  hard_count = Enum.count(mine, &(Metrics.hard_failures(&1) != []))
  totals = for metric <- soft, do: "#{metric} #{Float.round(Enum.sum(Enum.map(mine, &Map.fetch!(&1, metric))) * 1.0, 1)}"
  IO.puts("\n### Totals, #{direction}: #{hard_count} charts with hard failures; " <> Enum.join(totals, ", "))
end

File.write!(previous_file, Jason.encode!(cards, pretty: true))

rows =
  for {name, _graph} <- LayoutScenarios.all() do
    cells =
      for {direction, edges} <- modes do
        key = "#{name}-#{direction}-#{edges}"
        card = cards[key]
        flag = if Metrics.hard_failures(card) == [], do: "", else: " ⚠"

        ~s(<td style="vertical-align:top;padding:8px"><div><b>#{direction} / #{edges}</b>#{flag}</div>) <>
          ~s(<img src="#{key}.svg?v=#{label}" style="max-width:420px"><div style="font-size:12px">) <>
          "crossings #{card.crossings}, bends #{card.bends}, jogs #{card.jogs}, segments #{card.segments}, lateral #{card.lateral}, area #{card.area_ratio}</div></td>"
      end

    "<h2>#{name}</h2><table><tr>#{Enum.join(cells)}</tr></table>\n"
  end

File.write!(Path.join(dir, "index.html"), """
<!doctype html><meta charset="utf-8"><title>Layout gallery: #{label}, labels #{labels}</title>
<body style="font-family:sans-serif">
<h1>Layout gallery: #{label}, labels #{labels}</h1>
#{rows}
</body>
""")

IO.puts("\nWrote #{dir}/index.html")
