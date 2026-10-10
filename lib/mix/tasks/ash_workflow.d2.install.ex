defmodule Mix.Tasks.AshWorkflow.D2.Install do
  @shortdoc "Downloads the d2 binary that draws SVG diagrams"

  @moduledoc """
  #{@shortdoc}.

  `AshWorkflow.Charts.render(resource, :d2, svg: true)` and
  `mix ash_workflow.diagram --format d2 --svg` download `d2` the first time
  they run. This task downloads it ahead of time. Use it in a CI step that
  has network access, before the tests run. When `d2` is already there, the
  task does nothing. When `config :ash_workflow, :d2` sets `:path`, the task
  downloads nothing. It raises when `:path` names neither an executable file
  nor a command on the `PATH`.

  A release cannot use this download, because `mix release` does not copy
  it. See "Releases" in `AshWorkflow.Charts.D2.Binary`, which also explains
  the version, the checksum and the path.

  ## Example

  ```bash
  mix ash_workflow.d2.install
  ```
  """

  use Mix.Task

  alias AshWorkflow.Charts.D2.Binary

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_argv) do
    if Binary.installed?() do
      Mix.shell().info("d2 is already at #{Binary.ensure_installed!()}")
    else
      # With `:path` set, this raises and says that `:path` names no `d2`.
      path = Binary.ensure_installed!()
      Mix.shell().info("Installed d2 v#{Binary.version()} at #{path}")
    end
  end
end
