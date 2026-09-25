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
  it, such as `MyApp.Candidate.mmd`.

  In an umbrella project, run from the root, the task reads `:ash_domains`
  from every child application.

  ## Options

  * `--format` — a name from `AshWorkflow.Charts.formats/0`. Defaults to
    `mermaid`.
  * `--output` — the directory to write the files to.
  * `--no-undo` — leave out undo edges.
  * `--no-notes` — leave out step notes: policies, retry, timeouts that run
    an action, and `every` entries.

  See `AshWorkflow.Charts` for what each format shows.

  ## Example

  ```bash
  mix ash_workflow.diagram MyApp.Candidate
  mix ash_workflow.diagram --format json --output priv/diagrams
  ```
  """

  use Mix.Task

  alias Ash.Domain.Info, as: DomainInfo
  alias AshWorkflow.Charts
  alias AshWorkflow.Info

  @requirements ["app.config"]

  @switches [format: :string, output: :string, undo: :boolean, notes: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, names} = parse!(argv)
    format = format!(Keyword.get(opts, :format, "mermaid"))
    chart_opts = Keyword.take(opts, [:undo, :notes])
    resources = resources!(names)

    case Keyword.fetch(opts, :output) do
      {:ok, dir} -> write(resources, format, chart_opts, dir)
      :error -> Enum.each(resources, &Mix.shell().info(Charts.render(&1, format, chart_opts)))
    end
  end

  defp parse!(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, names, []} -> {opts, names}
      {_opts, _names, invalid} -> Mix.raise("Unknown options: #{inspect(invalid)}")
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

  defp write(resources, format, chart_opts, dir) do
    File.mkdir_p!(dir)
    extension = Charts.backend!(format).file_extension()

    for resource <- resources do
      path = Path.join(dir, "#{inspect(resource)}.#{extension}")
      File.write!(path, Charts.render(resource, format, chart_opts))
      Mix.shell().info("Wrote #{path}")
    end
  end
end
