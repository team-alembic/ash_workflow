defmodule AshWorkflow.Charts.MermaidTest do
  use ExUnit.Case, async: true

  alias AshWorkflow.Charts.Graph
  alias AshWorkflow.Charts.Graph.Edge
  alias AshWorkflow.Charts.Graph.Node
  alias AshWorkflow.Charts.Mermaid

  test "draws the full pipeline" do
    assert render(AshWorkflowTest.FullPipeline) == """
           stateDiagram-v2
               state "intake" as step_intake
               step_intake : ⚙ automatic
               state "review" as step_review
               step_review : ✋ manual
               state "on_hold" as step_on_hold
               step_on_hold : ✋ manual
               state "process" as step_process
               step_process : ⚙ automatic
               state "final_review" as step_final_review
               step_final_review : ✋ manual
               state "done" as step_done
               state "rejected" as step_rejected
               state "intake_failed" as step_intake_failed
               state "escalated" as step_escalated
               [*] --> step_intake
               step_intake --> step_review: ⚙ run_intake
               step_intake --> step_intake_failed: ✖ on_error
               step_review --> step_process: advance
               step_review --> step_rejected: reject_at_review
               step_review --> step_on_hold: hold
               step_review --> step_escalated: ⏱ after 7 days
               step_on_hold --> step_review: reactivate
               step_on_hold --> step_rejected: reject_on_hold
               step_process --> step_final_review: ⚙ run_processing
               step_final_review --> step_done: approve
               step_final_review --> step_rejected: reject_at_final
               note right of step_review
                   policy: actor.role == :reviewer
                   ⏱ after 2 days: send_review_reminder
               end note
               note right of step_on_hold
                   policy: actor.role == :reviewer
               end note
               note right of step_final_review
                   policy: actor.role == :approver
               end note
               step_done --> [*]
               step_rejected --> [*]
               step_intake_failed --> [*]
               step_escalated --> [*]
           """
  end

  test "adds each route's condition, with entity codes for < and >" do
    output = render(AshWorkflowTest.OnSuccessThreeWayWorkflow)

    assert output =~ "step_classifying --> step_low: ⚙ run_classification when score #60; 3\n"

    assert output =~
             "step_classifying --> step_mid: ⚙ run_classification when (score #62;= 3) and (score #60; 7)\n"
  end

  test "draws only the moves undo can rewind" do
    undo_lines =
      AshWorkflowTest.UndoWorkflow
      |> render()
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "↶ undo"))

    assert undo_lines == [
             "    step_publish --> step_review: ↶ undo",
             "    step_deferred --> step_review: ↶ undo",
             "    step_review --> step_deferred: ↶ undo",
             "    step_publish --> step_deferred: ↶ undo"
           ]
  end

  test "marks a wait state, a fire_at timeout and an every" do
    fire_at = render(AshWorkflowTest.FireAtWorkflow)

    assert fire_at =~ "    step_calculated : ⏳ wait state\n"
    assert fire_at =~ "    step_waiting --> step_reviewed: ⏱ at next_check_at\n"

    assert render(AshWorkflowTest.EveryUntilWorkflow) =~
             "        ↻ every 1 hour for 3 hours: send_reminder\n"
  end

  test "prefixes state IDs, so a step named after a Mermaid keyword still parses" do
    assert render(AshWorkflowTest.ChartKeywordWorkflow) == """
           stateDiagram-v2
               state "note" as step_note
               step_note : ✋ manual
               state "end" as step_end
               [*] --> step_note
               step_note --> step_end: close
               step_end --> [*]
           """
  end

  test "writes characters that Mermaid reads as syntax as entity codes" do
    graph = %Graph{
      resource: Example,
      nodes: [%Node{id: :a, kind: :manual, initial?: true}, %Node{id: :b, kind: :terminal}],
      edges: [
        %Edge{
          from: :a,
          to: :b,
          kind: :transition,
          name: :go,
          label: "go",
          condition: ~S(x == "a#b;c<d>e\f")
        }
      ]
    }

    output = graph |> Mermaid.render([]) |> IO.iodata_to_binary()

    assert output =~ ~S(step_a --> step_b: go when x == #34;a#35;b#59;c#60;d#62;e#92;f#34;)
  end

  test "adds otherwise to the last on_success route without a when" do
    output = render(AshWorkflowTest.OnSuccessFallbackWorkflow)

    assert output =~ "step_triaging --> step_escalated: ⚙ run_triage when priority == :high\n"
    assert output =~ "step_triaging --> step_queued: ⚙ run_triage otherwise\n"
  end

  test "shows a timeout's own retry policy in its note" do
    assert render(AshWorkflowTest.RetryWorkflow) =~
             "        ⏱ after 2 days: send_nudge, retry: 2 attempts, 30 seconds apart\n"
  end

  test "writes a colon as an entity code only where Mermaid's lexer would stop" do
    graph = %Graph{
      resource: Example,
      nodes: [%Node{id: :a, kind: :manual, initial?: true}, %Node{id: :b, kind: :terminal}],
      edges: [
        %Edge{
          from: :a,
          to: :b,
          kind: :transition,
          name: :go,
          label: "go",
          condition: ~S(x == "a::b")
        },
        %Edge{from: :a, to: :b, kind: :transition, name: :end, label: "ends with:"},
        %Edge{
          from: :a,
          to: :b,
          kind: :transition,
          name: :role,
          label: "role",
          condition: "role == :vip"
        }
      ]
    }

    output = graph |> Mermaid.render([]) |> IO.iodata_to_binary()

    assert output =~ ~S(step_a --> step_b: go when x == #34;a#58;:b#34;)
    assert output =~ "step_a --> step_b: ends with#58;\n"
    assert output =~ "step_a --> step_b: role when role == :vip\n"
  end

  test "encodes a non-ASCII character in a step name by its code point" do
    graph = %Graph{
      resource: Example,
      nodes: [%Node{id: :aprovação, kind: :terminal, initial?: true}],
      edges: []
    }

    output = graph |> Mermaid.render([]) |> IO.iodata_to_binary()

    assert output =~ ~S(state "aprovação" as step_aprova_E7_E3o)
  end

  test "refuses two step names that map to one ID" do
    graph = %Graph{
      resource: Example,
      nodes: [
        %Node{id: :"re-open", kind: :manual, initial?: true},
        %Node{id: :re_2Dopen, kind: :terminal}
      ],
      edges: []
    }

    assert_raise ArgumentError,
                 ~r/same Mermaid state ID: \[:"re-open", :re_2Dopen\] -> step_re_2Dopen/,
                 fn ->
                   Mermaid.render(graph, [])
                 end
  end

  test "gives distinct IDs to step names that differ only in punctuation" do
    graph = %Graph{
      resource: Example,
      nodes: [
        %Node{id: :"re-open", kind: :manual, initial?: true},
        %Node{id: :re_open, kind: :terminal}
      ],
      edges: [%Edge{from: :"re-open", to: :re_open, kind: :transition, name: :go, label: "go"}]
    }

    output = graph |> Mermaid.render([]) |> IO.iodata_to_binary()

    assert output =~ ~S(state "re-open" as step_re_2Dopen)
    assert output =~ ~S(state "re_open" as step_re_open)
    assert output =~ "step_re_2Dopen --> step_re_open: go\n"
  end

  test "takes no options" do
    graph = Graph.build(AshWorkflowTest.FullPipeline)

    assert_raise ArgumentError, fn -> Mermaid.render(graph, pretty: true) end
  end

  test "writes .mmd files" do
    assert Mermaid.file_extension() == "mmd"
  end

  defp render(resource) do
    resource |> Graph.build() |> Mermaid.render([]) |> IO.iodata_to_binary()
  end
end
