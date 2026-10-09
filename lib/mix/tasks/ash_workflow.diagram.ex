defmodule Mix.Tasks.AshWorkflow.Diagram do
  @shortdoc "Prints or writes a diagram of each AshWorkflow resource"

  @moduledoc """
  #{@shortdoc}.

  With resource names, draws those resources. With none, draws every resource
  that uses `AshWorkflow` in the domains this project lists under
  `:ash_domains`.

  Without `--output`, prints each diagram. With several resources, the
  diagrams follow one another, and `--format json` prints one JSON document
  per line. With `--output DIR`, writes one file per resource, named after
  it, such as `MyApp.Candidate.mmd`. The task draws every diagram first, so
  an error prints or writes nothing.

  In an umbrella project, run from the root, the task reads `:ash_domains`
  from every child application.

  ## Options

  * `--format` — a name from `AshWorkflow.Charts.formats/0`. Defaults to
    `mermaid`.
  * `--output` — the directory to write the files to.
  * `--svg` — with `--format dot`, draw the chart and print or write the
    SVG. The files end in `.svg`. Graphviz must be installed: see
    `AshWorkflow.Charts.Dot`.
  * `--theme` — with `--format dot`, `light` or `dark`. Defaults to the
    `:theme` under `config :ash_workflow, :dot`, else `light`. For a dark
    chart, a file name gets `-dark` before its extension, such as
    `MyApp.Candidate-dark.svg`. So a light run and a dark run can write to
    the same directory.
  * `--no-undo` — leave out undo edges.
  * `--no-notes` — leave out step notes: policies, retry, timeouts that run
    an action, and `every` entries.

  See `AshWorkflow.Charts` for what each format shows.

  ## Example

  ```bash
  mix ash_workflow.diagram MyApp.Candidate
  mix ash_workflow.diagram --format json --output priv/diagrams
  mix ash_workflow.diagram --format dot --svg --theme dark MyApp.Candidate
  ```
  """

  use Mix.Task

  alias Ash.Domain.Info, as: DomainInfo
  alias AshWorkflow.Charts
  alias AshWorkflow.Info

  @requirements ["app.config"]

  @switches [
    format: :string,
    output: :string,
    svg: :boolean,
    theme: :string,
    undo: :boolean,
    notes: :boolean
  ]

  # The formats that draw an SVG and take a theme.
  @svg_formats [:dot]

  @impl Mix.Task
  def run(argv) do
    {opts, names} = parse!(argv)
    format = format!(Keyword.get(opts, :format, "mermaid"))
    svg? = svg!(opts, format)

    chart_opts =
      Keyword.take(opts, [:undo, :notes]) ++
        if(svg?, do: [svg: true], else: []) ++ theme!(opts, format)

    resources = resources!(names)

    # Every chart is drawn before any output, so an error leaves no files
    # and no `--output` directory behind.
    charts =
      for resource <- resources do
        {resource, mix_error!(fn -> Charts.render(resource, format, chart_opts) end)}
      end

    case Keyword.fetch(opts, :output) do
      {:ok, dir} -> write(charts, format, chart_opts, dir, svg?)
      :error -> Enum.each(charts, fn {_resource, chart} -> Mix.shell().info(chart) end)
    end
  end

  # A backend raises `ArgumentError` for a bad option or config, or when it
  # cannot draw the SVG. The task shows the message, with no stack trace.
  defp mix_error!(fun) do
    fun.()
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end

  defp parse!(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, names, []} -> {opts, names}
      {_opts, _names, invalid} -> Mix.raise("Unknown options: #{inspect(invalid)}")
    end
  end

  defp theme!(opts, format) do
    case {Keyword.fetch(opts, :theme), format} do
      {:error, _format} ->
        []

      {{:ok, _theme}, format} when format not in @svg_formats ->
        Mix.raise("--theme needs --format dot, not #{format}")

      {{:ok, theme}, _format} when theme in ["light", "dark"] ->
        [theme: String.to_atom(theme)]

      {{:ok, theme}, _format} ->
        Mix.raise("--theme must be light or dark, not #{inspect(theme)}")
    end
  end

  defp svg!(opts, format) do
    case {Keyword.get(opts, :svg, false), format} do
      {false, _format} -> false
      {true, format} when format in @svg_formats -> true
      {true, format} -> Mix.raise("--svg needs --format dot, not #{format}")
    end
  end

  defp format!(name) do
    Enum.find(Charts.formats(), &(Atom.to_string(&1) == name)) ||
      Mix.raise(
        "Unknown format #{inspect(name)}. Use one of: #{Enum.join(Charts.formats(), ", ")}"
      )
  end

  defp resources!([]) do
    apps = apps()

    resources =
      apps
      |> Enum.flat_map(&Ash.Info.domains/1)
      |> Enum.flat_map(&DomainInfo.resources/1)
      |> Enum.uniq()
      |> Enum.filter(&Info.workflow?/1)

    if resources == [] do
      Mix.raise(
        "No resource that uses AshWorkflow was found in the domains configured under " <>
          ":ash_domains for #{inspect(apps)}. Name a resource, or configure :ash_domains."
      )
    end

    resources
  end

  defp resources!(names), do: Enum.map(names, &resource!/1)

  defp apps do
    if Mix.Project.umbrella?(),
      do: Map.keys(Mix.Project.apps_paths()),
      else: [Mix.Project.config()[:app]]
  end

  defp resource!(name) do
    module = Module.concat([name])

    cond do
      not Code.ensure_loaded?(module) ->
        Mix.raise(
          "Module #{name} could not be loaded. Check the name and that the project compiles."
        )

      not Info.workflow?(module) ->
        Mix.raise("#{name} is not a resource that uses AshWorkflow")

      true ->
        module
    end
  end

  defp write(charts, format, chart_opts, dir, svg?) do
    backend = Charts.backend!(format)
    extension = if svg?, do: "svg", else: backend.file_extension()

    suffix =
      if format in @svg_formats and mix_error!(fn -> backend.theme(chart_opts) end) == :dark,
        do: "-dark",
        else: ""

    File.mkdir_p!(dir)

    for {resource, chart} <- charts do
      path = Path.join(dir, "#{inspect(resource)}#{suffix}.#{extension}")
      File.write!(path, chart)
      Mix.shell().info("Wrote #{path}")
    end
  end
end
