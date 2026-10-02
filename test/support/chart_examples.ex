defmodule AshWorkflowTest.ChartExamples do
  @moduledoc """
  Generates the chart examples in the guides from the workflows in `examples/`.

  A guide marks each generated block with a pair of HTML comments. The opening
  comment names the resource and the format, and everything up to the closing
  comment is generated:

      <!-- chart: BasicWorkflow.DocumentApproval mermaid -->
      ```mermaid
      ...
      ```
      <!-- /chart -->

  The format is one of these:

  * `workflow` — the resource's `workflow do ... end` block, copied from its
    source file, so a guide shows the definition next to its chart.
  * `mermaid` — the chart, from `AshWorkflow.Charts.render/3`.
  * `json` — the chart as indented JSON.
  * `d2` — the chart as D2 source.
  * `dot` — the chart as Graphviz DOT source.

  `test/documentation_charts_test.exs` fails when a block is out of date, and
  `bin/update-chart-examples` rewrites every block. The comments do not show
  in ExDoc or on GitHub.

  Neither GitHub nor ExDoc draws D2 or DOT, so the guide shows each of these
  charts as an SVG file under `documentation/topics/assets/`, which `svgs/0`
  lists and `update!/0` writes: a D2 chart with the pinned `d2`, and a DOT
  chart with the `dot` of the installed Graphviz. The test checks that each
  file exists and is an SVG, not its bytes: another `d2` or `dot` version
  lays the same diagram out differently.

  The examples come from `examples/`, which compiles only in the test
  environment, where this module also compiles. That is why the script runs a
  `:test` build, and why `mix docs`, which runs in `:dev`, does not regenerate
  the blocks itself: the test is what keeps the committed guides current.
  """

  alias AshWorkflow.Charts

  # The body may not hold another opening marker, so a block with a missing
  # closing marker is left alone, and `count/1` then reports one block fewer.
  @marker ~r/(<!-- chart: ([A-Z][\w.]*) (mermaid|json|d2|dot|workflow) -->\n)((?:(?!<!-- chart:).)*?)(<!-- \/chart -->)/s

  @doc """
  The guides that can hold generated blocks.
  """
  @spec files() :: [Path.t()]
  def files, do: Path.wildcard("documentation/topics/*.md")

  @doc """
  The contents with every marked block generated again.
  """
  @spec render(String.t()) :: String.t()
  def render(contents) do
    Regex.replace(@marker, contents, fn _match, open, resource, format, _old, close ->
      open <> block(Module.concat([resource]), String.to_existing_atom(format)) <> close
    end)
  end

  @doc """
  The number of marked blocks in the contents.
  """
  @spec count(String.t()) :: non_neg_integer()
  def count(contents), do: @marker |> Regex.scan(contents) |> length()

  @doc """
  One fenced block: a resource's workflow definition, or its chart in a
  format.
  """
  @spec block(Ash.Resource.t(), :workflow | :mermaid | :json | :d2 | :dot) :: String.t()
  def block(resource, :workflow), do: "```elixir\n" <> workflow_source(resource) <> "```\n"

  def block(resource, :d2), do: "```d2\n" <> Charts.render(resource, :d2) <> "```\n"

  def block(resource, :dot), do: "```dot\n" <> Charts.render(resource, :dot) <> "```\n"

  def block(resource, :mermaid),
    do: "```mermaid\n" <> Charts.render(resource, :mermaid) <> "```\n"

  def block(resource, :json),
    do: "```json\n" <> Charts.render(resource, :json, pretty: true) <> "\n```\n"

  # The `workflow do ... end` block of the resource's source file, without its
  # indentation. The lines come from the parsed code, so a `workflow do` sample
  # inside the moduledoc, which is a string, cannot be taken for the
  # definition.
  defp workflow_source(resource) do
    source = resource |> source_path() |> File.read!()
    {first, last} = workflow_lines(resource, source)
    lines = source |> String.split(~r/\r?\n/) |> Enum.slice((first - 1)..(last - 1)//1)
    indent = String.replace_suffix(hd(lines), "workflow do", "")

    Enum.map_join(lines, "\n", &String.replace_prefix(&1, indent, "")) <> "\n"
  end

  defp workflow_lines(resource, source) do
    source
    |> Code.string_to_quoted!(token_metadata: true)
    |> Macro.prewalk([], fn
      {:workflow, meta, [[do: _block]]} = node, acc ->
        {node, [{meta[:line], meta[:end][:line]} | acc]}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> case do
      [lines] ->
        lines

      [] ->
        raise ArgumentError, "#{inspect(resource)} has no `workflow do` block in its source file"
    end
  end

  # The compiler records the source as an absolute path. This re-roots it at
  # the project's `examples` directory, the last one in the path, so a build
  # made in another checkout of the repository still finds the file.
  defp source_path(resource) do
    parts =
      resource.module_info(:compile) |> Keyword.fetch!(:source) |> to_string() |> Path.split()

    case parts |> Enum.reverse() |> Enum.find_index(&(&1 == "examples")) do
      nil -> Path.join(parts)
      from_end -> parts |> Enum.take(-(from_end + 1)) |> Path.join()
    end
  end

  @doc """
  The SVG files the guides show: the path, the resource each one draws, its
  format, and the options it uses.
  """
  @spec svgs() :: [{Path.t(), Ash.Resource.t(), :d2 | :dot, keyword()}]
  def svgs do
    [
      {"documentation/topics/assets/incident-d2.svg", BasicWorkflow.Incident, :d2, []},
      {"documentation/topics/assets/incident-d2-dark.svg", BasicWorkflow.Incident, :d2,
       [theme: :dark]},
      {"documentation/topics/assets/incident-dot.svg", BasicWorkflow.Incident, :dot, []},
      {"documentation/topics/assets/incident-dot-dark.svg", BasicWorkflow.Incident, :dot,
       [theme: :dark]}
    ]
  end

  @doc """
  Rewrites every guide whose generated blocks are out of date, and every SVG
  whose content changed, and returns the paths it wrote.
  """
  @spec update!() :: [Path.t()]
  def update! do
    guides =
      for file <- files(),
          contents = File.read!(file),
          updated = render(contents),
          updated != contents do
        File.write!(file, updated)
        file
      end

    svgs =
      for {file, resource, format, opts} <- svgs(),
          svg = Charts.render(resource, format, [svg: true] ++ opts),
          not File.exists?(file) or File.read!(file) != svg do
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, svg)
        file
      end

    guides ++ svgs
  end
end
