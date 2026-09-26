defmodule AshWorkflow.Charts.JsonTest do
  use ExUnit.Case, async: true

  alias AshWorkflow.Charts.Graph
  alias AshWorkflow.Charts.Json

  test "to_map/1 gives string keys and values any JSON encoder accepts" do
    map = AshWorkflowTest.PolicyWorkflow |> Graph.build() |> Json.to_map()

    assert map == %{
             "resource" => "AshWorkflowTest.PolicyWorkflow",
             "nodes" => [
               %{
                 "id" => "manager_review",
                 "kind" => "manual",
                 "initial" => true,
                 "notes" => [
                   %{
                     "kind" => "policy",
                     "name" => nil,
                     "action" => nil,
                     "label" => "actor.role == :manager",
                     "retry" => nil
                   }
                 ]
               },
               %{"id" => "approved", "kind" => "terminal", "initial" => false, "notes" => []},
               %{"id" => "rejected", "kind" => "terminal", "initial" => false, "notes" => []}
             ],
             "edges" => [
               %{
                 "from" => "manager_review",
                 "to" => "approved",
                 "kind" => "transition",
                 "name" => "approve",
                 "label" => "approve",
                 "condition" => nil,
                 "fallback" => false
               },
               %{
                 "from" => "manager_review",
                 "to" => "rejected",
                 "kind" => "transition",
                 "name" => "reject",
                 "label" => "reject",
                 "condition" => nil,
                 "fallback" => false
               }
             ]
           }
  end

  test "to_map/1 carries route conditions and undo edges" do
    map = AshWorkflowTest.UndoWorkflow |> Graph.build() |> Json.to_map()

    assert %{
             "from" => "deferred",
             "to" => "review",
             "kind" => "transition",
             "name" => "resume",
             "condition" => "priority == :normal"
           } = Enum.at(map["edges"], 4)

    assert Enum.count(map["edges"], &(&1["kind"] == "undo")) == 4
  end

  test "render/2 encodes the map to_map/1 returns" do
    graph = Graph.build(AshWorkflowTest.FullPipeline)

    assert graph |> Json.render([]) |> IO.iodata_to_binary() |> Jason.decode!() ==
             Json.to_map(graph)
  end

  test "render/2 indents with pretty: true" do
    output =
      AshWorkflowTest.PolicyWorkflow
      |> Graph.build()
      |> Json.render(pretty: true)
      |> IO.iodata_to_binary()

    assert output =~ "\n  \"edges\": ["
  end

  test "writes .json files" do
    assert Json.file_extension() == "json"
  end
end
