defmodule AshWorkflowTest.LayoutScenarios do
  @moduledoc false
  # The spike's scenario corpus: the guide workflows, the test fixtures that
  # have loops and conditions, and small hand-built graphs that each probe one
  # layout problem.

  alias AshWorkflow.Charts
  alias AshWorkflow.Charts.Graph
  alias AshWorkflow.Charts.Graph.Edge
  alias AshWorkflow.Charts.Graph.Node

  @resources [
    BasicWorkflow.DocumentApproval,
    BasicWorkflow.Incident,
    BasicWorkflow.Subscription,
    BasicWorkflow.ScheduledPost,
    AshWorkflowTest.FullPipeline,
    AshWorkflowTest.ConditionalWorkflow,
    AshWorkflowTest.OnSuccessThreeWayWorkflow,
    AshWorkflowTest.OnSuccessFallbackWorkflow,
    AshWorkflowTest.UndoWorkflow,
    AshWorkflowTest.WaitStateWorkflow,
    AshWorkflowTest.RetryWorkflow,
    AshWorkflowTest.EveryUntilWorkflow,
    AshWorkflowTest.LoopbackWorkflow,
    AshWorkflowTest.OnSuccessBackwardLoopWorkflow,
    AshWorkflowTest.OnSuccessSelfLoopWorkflow
  ]

  def all, do: workflows() ++ probes()

  def workflows do
    for resource <- @resources,
        do:
          {resource |> Module.split() |> List.last() |> Macro.underscore(),
           Charts.graph(resource)}
  end

  def probes do
    [
      {"probe_chain", graph([:a, :b, :c, :d, :e], [t(:a, :b), t(:b, :c), t(:c, :d), t(:d, :e)])},
      {"probe_fan_out",
       graph([:a, :b, :c, :d, :e], [t(:a, :b), t(:a, :c), t(:a, :d), t(:a, :e)])},
      {"probe_fan_in",
       graph([:a, :b, :c, :d, :e], [
         t(:a, :b),
         t(:a, :c),
         t(:a, :d),
         t(:b, :e),
         t(:c, :e),
         t(:d, :e)
       ])},
      {"probe_diamond", graph([:a, :b, :c, :d], [t(:a, :b), t(:a, :c), t(:b, :d), t(:c, :d)])},
      {"probe_long_edge",
       graph([:a, :b, :c, :d, :e], [
         t(:a, :b),
         t(:b, :c),
         t(:c, :d),
         t(:d, :e),
         t(:a, :e, "skip_ahead")
       ])},
      {"probe_retry_loop",
       graph([:a, :b, :c, :d], [t(:a, :b), t(:b, :c), t(:c, :b, "retry"), t(:c, :d)])},
      {"probe_undo_chain", graph([:a, :b, :c], [t(:a, :b), t(:b, :c), u(:c, :b), u(:b, :a)])},
      {"probe_parallel",
       graph([:a, :b], [
         t(:a, :b, "approve"),
         %Edge{from: :a, to: :b, kind: :timeout, name: :expire, label: "after 7 days"}
       ])},
      {"probe_self_loop", graph([:a, :b], [t(:a, :a, "remind"), t(:a, :b)])},
      {"probe_crossing_bait",
       graph(
         [:a1, :a2, :b1, :b2, :root],
         [t(:root, :a1), t(:root, :a2), t(:a1, :b2), t(:a2, :b1)],
         :root
       )},
      {"probe_wide_labels",
       graph([:a, :b, :c], [
         %Edge{
           from: :a,
           to: :b,
           kind: :transition,
           name: :go,
           label: "go",
           condition: "amount > 10_000 and region in [:eu, :uk] and not flagged?"
         },
         t(:a, :c, "stop")
       ])}
    ]
  end

  defp graph(ids, edges, initial \\ nil) do
    initial = initial || hd(ids)
    sources = MapSet.new(edges, & &1.from)

    nodes =
      for id <- ids do
        kind = if MapSet.member?(sources, id), do: :manual, else: :terminal
        %Node{id: id, kind: kind, initial?: id == initial}
      end

    %Graph{resource: nil, nodes: nodes, edges: edges}
  end

  defp t(from, to, label \\ nil),
    do: %Edge{
      from: from,
      to: to,
      kind: :transition,
      name: :go,
      label: label || "#{from}_to_#{to}"
    }

  defp u(from, to), do: %Edge{from: from, to: to, kind: :undo, name: :undo, label: "undo"}
end
