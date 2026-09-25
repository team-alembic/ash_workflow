defmodule AshWorkflow.ChartsTest do
  use ExUnit.Case, async: true

  alias AshWorkflow.Charts

  defmodule EdgeCountBackend do
    @moduledoc false
    @behaviour AshWorkflow.Charts.Backend

    @impl true
    def render(graph, opts), do: "#{length(graph.edges)} edges#{opts[:suffix]}"

    @impl true
    def file_extension, do: "txt"
  end

  test "formats/0 lists the formats this library ships" do
    assert Charts.formats() == [:mermaid, :json]
  end

  test "backend!/1 accepts a format name or a backend module" do
    assert Charts.backend!(:mermaid) == AshWorkflow.Charts.Mermaid
    assert Charts.backend!(:json) == AshWorkflow.Charts.Json
    assert Charts.backend!(EdgeCountBackend) == EdgeCountBackend
  end

  defmodule RenderOnlyBackend do
    @moduledoc false
    def render(_graph, _opts), do: ""
  end

  test "backend!/1 raises for anything else" do
    assert_raise ArgumentError, ~r/unknown chart format :svg/, fn -> Charts.backend!(:svg) end

    assert_raise ArgumentError, ~r/unknown chart format "mermaid"/, fn ->
      Charts.backend!("mermaid")
    end

    assert_raise ArgumentError, ~r/unknown chart format/, fn ->
      Charts.backend!(RenderOnlyBackend)
    end
  end

  test "render/3 gives :undo and :notes to the graph, and other options to the backend" do
    assert Charts.render(AshWorkflowTest.UndoWorkflow, EdgeCountBackend) == "10 edges"

    assert Charts.render(AshWorkflowTest.UndoWorkflow, EdgeCountBackend, undo: false, suffix: "!") ==
             "6 edges!"
  end

  test "render/3 returns the Mermaid diagram as a string" do
    assert Charts.render(AshWorkflowTest.PolicyWorkflow, :mermaid) =~ ~r/\AstateDiagram-v2\n/
  end

  test "mermaid_state_diagram/2 is render/3 with :mermaid" do
    assert Charts.mermaid_state_diagram(AshWorkflowTest.UndoWorkflow, undo: false) ==
             Charts.render(AshWorkflowTest.UndoWorkflow, :mermaid, undo: false)
  end
end
