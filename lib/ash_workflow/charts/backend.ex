defmodule AshWorkflow.Charts.Backend do
  @moduledoc """
  The contract a diagram format implements.

  A backend receives an `AshWorkflow.Charts.Graph` and returns the diagram as
  iodata. It decides only how each node kind and edge kind looks. It does not
  read the DSL, and it does not write labels, because the graph already
  carries them.

  `AshWorkflow.Charts.render/3` accepts a backend module in place of a format
  name, so a format this library does not ship needs no change here:

      defmodule MyApp.PlainTextChart do
        @behaviour AshWorkflow.Charts.Backend

        @impl true
        def render(graph, _opts) do
          for edge <- graph.edges, do: "\#{edge.from} -> \#{edge.to}: \#{edge.label}\\n"
        end

        @impl true
        def file_extension, do: "txt"
      end

      AshWorkflow.Charts.render(MyApp.Candidate, MyApp.PlainTextChart)
  """

  @doc """
  Draws the graph. `opts` holds the options `AshWorkflow.Charts.render/3` does
  not use itself.
  """
  @callback render(AshWorkflow.Charts.Graph.t(), keyword()) :: iodata()

  @doc """
  The file extension `mix ash_workflow.diagram --output` gives this format,
  without the dot.
  """
  @callback file_extension() :: String.t()
end
