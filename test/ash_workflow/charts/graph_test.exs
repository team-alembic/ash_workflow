defmodule AshWorkflow.Charts.GraphTest do
  use ExUnit.Case, async: true

  alias AshWorkflow.Charts.Graph
  alias AshWorkflow.Charts.Graph.Edge
  alias AshWorkflow.Charts.Graph.Node
  alias AshWorkflow.Charts.Graph.Note

  describe "nodes" do
    test "are in declaration order, with each step's kind and initial flag" do
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      assert Enum.map(graph.nodes, &{&1.id, &1.kind, &1.initial?}) == [
               {:intake, :automatic, true},
               {:review, :manual, false},
               {:on_hold, :manual, false},
               {:process, :automatic, false},
               {:final_review, :manual, false},
               {:done, :terminal, false},
               {:rejected, :terminal, false},
               {:intake_failed, :terminal, false},
               {:escalated, :terminal, false}
             ]
    end

    test "a step whose only exit is a timeout is a wait state" do
      graph = Graph.build(AshWorkflowTest.WaitStateWorkflow)

      assert %Node{kind: :wait_state, initial?: true} = find_node(graph, :queued)
    end

    test "notes hold the policy and the timeouts that run an action" do
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      assert find_node(graph, :review).notes == [
               %Note{kind: :policy, label: "actor.role == :reviewer"},
               %Note{
                 kind: :timeout,
                 name: :reminder,
                 action: :send_review_reminder,
                 label: "after 2 days"
               }
             ]
    end

    test "notes hold a retry policy only when it allows more than one attempt" do
      graph = Graph.build(AshWorkflowTest.RetryWorkflow)

      assert find_node(graph, :no_retry).notes == []

      assert find_node(graph, :fixed_backoff).notes == [
               %Note{kind: :retry, label: "3 attempts, 10 seconds apart"}
             ]
    end

    test "a timeout note carries the timeout's own retry policy" do
      graph = Graph.build(AshWorkflowTest.RetryWorkflow)

      assert [%Note{kind: :timeout, name: :nudge, retry: "2 attempts, 30 seconds apart"}] =
               find_node(graph, :waiting).notes

      assert [%Note{kind: :timeout, name: :reminder, retry: nil}] =
               AshWorkflowTest.FullPipeline
               |> Graph.build()
               |> find_node(:review)
               |> Map.fetch!(:notes)
               |> Enum.filter(&(&1.kind == :timeout))
    end

    test "notes hold every entries" do
      graph = Graph.build(AshWorkflowTest.EveryUntilWorkflow)

      assert find_node(graph, :waiting).notes == [
               %Note{
                 kind: :every,
                 name: :reminder,
                 action: :send_reminder,
                 label: "every 1 hour for 3 hours"
               }
             ]
    end

    test "notes: false leaves every note out" do
      graph = Graph.build(AshWorkflowTest.FullPipeline, notes: false)

      assert Enum.all?(graph.nodes, &(&1.notes == []))
    end
  end

  describe "edges" do
    test "are grouped by step: on_success, transitions, timeouts, then on_error" do
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      assert Enum.map(graph.edges, &{&1.from, &1.to, &1.kind, &1.label}) == [
               {:intake, :review, :on_success, "run_intake"},
               {:intake, :intake_failed, :on_error, "on_error"},
               {:review, :process, :transition, "advance"},
               {:review, :rejected, :transition, "reject_at_review"},
               {:review, :on_hold, :transition, "hold"},
               {:review, :escalated, :timeout, "after 7 days"},
               {:on_hold, :review, :transition, "reactivate"},
               {:on_hold, :rejected, :transition, "reject_on_hold"},
               {:process, :final_review, :on_success, "run_processing"},
               {:final_review, :done, :transition, "approve"},
               {:final_review, :rejected, :transition, "reject_at_final"}
             ]
    end

    test "a conditional transition gives one edge per route, with its condition" do
      graph = Graph.build(AshWorkflowTest.ConditionalWorkflow)

      assert [
               %Edge{to: :training, condition: "path_type == :full"},
               %Edge{to: :fast_track, condition: "path_type == :abbreviated"}
             ] = Enum.filter(graph.edges, &(&1.name == :complete))
    end

    test "a conditional on_success gives one edge per route, with its condition" do
      graph = Graph.build(AshWorkflowTest.OnSuccessThreeWayWorkflow)

      assert graph.edges |> Enum.filter(&(&1.kind == :on_success)) |> Enum.map(& &1.condition) ==
               ["score < 3", "(score >= 3) and (score < 7)", "score >= 7"]
    end

    test "the last on_success route without a when is the fallback" do
      graph = Graph.build(AshWorkflowTest.OnSuccessFallbackWorkflow)
      routes = Enum.filter(graph.edges, &(&1.kind == :on_success))

      assert Enum.map(routes, &{&1.condition, &1.fallback?}) ==
               [{"priority == :high", false}, {nil, true}]

      assert [%Edge{condition: nil, fallback?: false}] =
               AshWorkflowTest.FullPipeline
               |> Graph.build()
               |> Map.fetch!(:edges)
               |> Enum.filter(&(&1.kind == :on_success and &1.from == :intake))
    end

    test "a timeout names its anchor field, or the field that holds its instant" do
      assert %Edge{label: "1 minute after release_at"} =
               first_timeout_edge(AshWorkflowTest.WaitStateWorkflow)

      assert %Edge{label: "at next_check_at"} = first_timeout_edge(AshWorkflowTest.FireAtWorkflow)
    end
  end

  describe "undo edges" do
    test "reverse exactly the moves undo can rewind, and come last" do
      graph = Graph.build(AshWorkflowTest.UndoWorkflow)
      undo_edges = Enum.filter(graph.edges, &(&1.kind == :undo))

      assert Enum.map(undo_edges, &{&1.from, &1.to}) == [
               publish: :review,
               deferred: :review,
               review: :deferred,
               publish: :deferred
             ]

      assert List.last(graph.edges).kind == :undo
    end

    test "undo: false leaves them out" do
      graph = Graph.build(AshWorkflowTest.UndoWorkflow, undo: false)

      refute Enum.any?(graph.edges, &(&1.kind == :undo))
    end

    test "a workflow without an undo block has none" do
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      refute Enum.any?(graph.edges, &(&1.kind == :undo))
    end
  end

  describe "errors" do
    test "raises for a module that is not a workflow resource" do
      assert_raise ArgumentError, ~r/is not a resource that uses AshWorkflow/, fn ->
        Graph.build(AshWorkflowTest.Reviewer)
      end

      assert_raise ArgumentError, ~r/is not a resource that uses AshWorkflow/, fn ->
        Graph.build(String)
      end
    end

    test "raises for an unknown option" do
      assert_raise ArgumentError, fn ->
        Graph.build(AshWorkflowTest.FullPipeline, undos: false)
      end
    end
  end

  defp find_node(graph, id), do: Enum.find(graph.nodes, &(&1.id == id))

  defp first_timeout_edge(resource) do
    resource |> Graph.build() |> Map.fetch!(:edges) |> Enum.find(&(&1.kind == :timeout))
  end
end
