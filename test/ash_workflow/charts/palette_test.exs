defmodule AshWorkflow.Charts.PaletteTest do
  use ExUnit.Case, async: true

  alias AshWorkflow.Charts.Graph
  alias AshWorkflow.Charts.Graph.Edge
  alias AshWorkflow.Charts.Graph.Node
  alias AshWorkflow.Charts.Palette

  describe "terminal_class/2" do
    test "reads the kinds of the edges that reach the step, and ignores undo" do
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      assert Palette.terminal_class(:done, graph) == :done
      assert Palette.terminal_class(:intake_failed, graph) == :failed
      assert Palette.terminal_class(:escalated, graph) == :expired
    end

    test "gives done to a step a person chooses, whatever its name" do
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      assert Palette.terminal_class(:rejected, graph) == :done
    end

    test "gives end to a mix of kinds and to a step nothing reaches" do
      mixed = %Graph{
        resource: Example,
        nodes: [%Node{id: :a, kind: :automatic, initial?: true}, %Node{id: :z, kind: :terminal}],
        edges: [
          %Edge{from: :a, to: :z, kind: :on_error, name: :run, label: "on_error"},
          %Edge{from: :a, to: :z, kind: :timeout, name: :late, label: "after 1 day"},
          %Edge{from: :z, to: :a, kind: :undo, name: :undo, label: "undo"}
        ]
      }

      assert Palette.terminal_class(:z, mixed) == :end
      assert Palette.terminal_class(:nowhere, mixed) == :end
    end
  end

  test "gives the background and the edge label colour of each theme" do
    assert Palette.background(:light) == "#FFFFFF"
    assert Palette.background(:dark) == "#1E1E2E"
    assert Palette.edge_label_colour(:light) == "#0A0F25"
    assert Palette.edge_label_colour(:dark) == "#F8FAFC"
  end
end
