defmodule AshWorkflow.Charts do
  @moduledoc """
  Draws a workflow as a diagram.

  A chart reads the workflow DSL, so it shows which steps are automatic,
  manual, wait states or terminal. It labels timeouts with their deadlines,
  shows the condition of each route, and draws the moves the generated `undo`
  action can make. For a chart of the generated state machine itself, use
  `AshStateMachine.Charts`.

      AshWorkflow.Charts.mermaid_state_diagram(MyApp.Candidate)
      AshWorkflow.Charts.render(MyApp.Candidate, :json, pretty: true)

  Each format is a module that implements `AshWorkflow.Charts.Backend`, and all
  of them draw from the same `AshWorkflow.Charts.Graph`. The formats this
  library ships are:

  * `:mermaid` — `AshWorkflow.Charts.Mermaid`, a Mermaid `stateDiagram-v2`.
  * `:json` — `AshWorkflow.Charts.Json`, plain data for a client that draws
    the workflow itself.
  * `:d2` — `AshWorkflow.Charts.D2`, a D2 chart with colour and line styles.
    `svg: true` draws it as SVG.

  `mix ash_workflow.diagram` writes the same output from the command line.
  """

  alias AshWorkflow.Charts.Graph

  @backends [
    mermaid: AshWorkflow.Charts.Mermaid,
    json: AshWorkflow.Charts.Json,
    d2: AshWorkflow.Charts.D2
  ]
  @graph_options [:undo, :notes]

  @doc """
  The format names `render/3` accepts in place of a backend module.
  """
  @spec formats() :: [atom()]
  def formats, do: Keyword.keys(@backends)

  @doc """
  The backend module for a format name, or the module itself when it
  implements `AshWorkflow.Charts.Backend`. Raises `ArgumentError` otherwise.
  """
  @spec backend!(term()) :: module()
  def backend!(format) when is_atom(format) do
    case Keyword.fetch(@backends, format) do
      {:ok, backend} -> backend
      :error -> custom_backend!(format)
    end
  end

  def backend!(other), do: unknown_format!(other)

  defp custom_backend!(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :render, 2) and
         function_exported?(module, :file_extension, 0) do
      module
    else
      unknown_format!(module)
    end
  end

  defp unknown_format!(format) do
    raise ArgumentError,
          "unknown chart format #{inspect(format)}. Use one of #{inspect(formats())}, " <>
            "or a module that implements AshWorkflow.Charts.Backend"
  end

  @doc """
  The diagram model for a resource. See `AshWorkflow.Charts.Graph.build/2`.
  """
  @spec graph(Ash.Resource.t(), keyword()) :: Graph.t()
  def graph(resource, opts \\ []), do: Graph.build(resource, opts)

  @doc """
  Draws a resource's workflow in a format, and returns the diagram as a string.

  ## Options

  `:undo` and `:notes` go to `AshWorkflow.Charts.Graph.build/2`. Every other
  option goes to the backend, for example `:pretty` for `:json`.
  """
  @spec render(Ash.Resource.t(), atom(), keyword()) :: String.t()
  def render(resource, format, opts \\ []) do
    {graph_opts, backend_opts} = Keyword.split(opts, @graph_options)
    backend = backend!(format)

    resource
    |> Graph.build(graph_opts)
    |> backend.render(backend_opts)
    |> IO.iodata_to_binary()
  end

  @doc """
  Draws a resource's workflow as a Mermaid `stateDiagram-v2`. The same as
  `render(resource, :mermaid, opts)`.
  """
  @spec mermaid_state_diagram(Ash.Resource.t(), keyword()) :: String.t()
  def mermaid_state_diagram(resource, opts \\ []), do: render(resource, :mermaid, opts)
end
