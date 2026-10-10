defmodule AshWorkflow.Charts.D2Test do
  use ExUnit.Case, async: true

  alias AshWorkflow.Charts.D2
  alias AshWorkflow.Charts.Graph
  alias AshWorkflow.Charts.Graph.Edge
  alias AshWorkflow.Charts.Graph.Node
  alias AshWorkflow.Charts.Graph.Note

  @fixtures [
    AshWorkflowTest.FullPipeline,
    AshWorkflowTest.ConditionalWorkflow,
    AshWorkflowTest.OnSuccessThreeWayWorkflow,
    AshWorkflowTest.OnSuccessFallbackWorkflow,
    AshWorkflowTest.UndoWorkflow,
    AshWorkflowTest.WaitStateWorkflow,
    AshWorkflowTest.FireAtWorkflow,
    AshWorkflowTest.RetryWorkflow,
    AshWorkflowTest.EveryUntilWorkflow,
    AshWorkflowTest.ChartKeywordWorkflow,
    BasicWorkflow.DocumentApproval,
    BasicWorkflow.Incident,
    BasicWorkflow.Subscription,
    BasicWorkflow.ScheduledPost
  ]

  test "draws the full pipeline" do
    assert render(AshWorkflowTest.FullPipeline) == ~S"""
           vars: {
             d2-config: {
               layout-engine: elk
               theme-id: 0
             }
           }
           direction: down
           classes: {
             automatic: {style: {fill: "#E8F0FE"; stroke: "#1A56DB"; border-radius: 4}}
             manual: {style: {fill: "#FFF4E5"; stroke: "#B7791F"; border-radius: 4}}
             wait_state: {style: {fill: "#F3E8FF"; stroke: "#6B46C1"; stroke-dash: 3; border-radius: 4}}
             done: {style: {fill: "#E6F4EA"; stroke: "#1E7B34"; double-border: true}}
             failed: {style: {fill: "#FDE8E8"; stroke: "#C81E1E"; double-border: true}}
             expired: {style: {fill: "#FEF3C7"; stroke: "#B45309"; double-border: true}}
             end: {style: {fill: "#F3F4F6"; stroke: "#4B5563"; double-border: true}}
             on_success: {style: {stroke: "#1A56DB"; stroke-width: 3}}
             on_error: {style: {stroke: "#C81E1E"}}
             timeout: {style: {stroke: "#B45309"; stroke-dash: 5}}
             undo: {style: {stroke: "#6B7280"; stroke-dash: 2}}
           }
           start: "" {shape: circle; width: 16; height: 16}
           step_intake: "intake\n⚙️ automatic" {class: automatic}
           step_review: "review\n✋ manual\n—\npolicy: actor.role == :reviewer\n⏱ after 2 days: send_review_reminder" {class: manual}
           step_on_hold: "on_hold\n✋ manual\n—\npolicy: actor.role == :reviewer" {class: manual}
           step_process: "process\n⚙️ automatic" {class: automatic}
           step_final_review: "final_review\n✋ manual\n—\npolicy: actor.role == :approver" {class: manual}
           step_done: "done" {class: done}
           step_rejected: "rejected" {class: done}
           step_intake_failed: "intake_failed" {class: failed}
           step_escalated: "escalated" {class: expired}
           start -> step_intake
           step_intake -> step_review: "⚙ run_intake" {class: on_success}
           step_intake -> step_intake_failed: "✖ on_error" {class: on_error}
           step_review -> step_process: "advance"
           step_review -> step_rejected: "reject_at_review"
           step_review -> step_on_hold: "hold"
           step_review -> step_escalated: "⏱ escalation after 7 days" {class: timeout}
           step_on_hold -> step_review: "reactivate"
           step_on_hold -> step_rejected: "reject_on_hold"
           step_process -> step_final_review: "⚙ run_processing" {class: on_success}
           step_final_review -> step_done: "approve"
           step_final_review -> step_rejected: "reject_at_final"
           """
  end

  test "classes a wait state and an undo edge" do
    assert render(AshWorkflowTest.WaitStateWorkflow) =~
             ~S(step_queued: "queued\n⏳ wait state" {class: wait_state})

    assert render(AshWorkflowTest.UndoWorkflow) =~
             ~S(step_publish -> step_review: "↶ undo within 1 hour" {class: undo})
  end

  test "adds otherwise to the last on_success route without a when" do
    assert render(AshWorkflowTest.OnSuccessFallbackWorkflow) =~
             ~S(step_triaging -> step_queued: "⚙ run_triage otherwise" {class: on_success})
  end

  test "keeps the notes of a terminal step, as the other formats do" do
    graph = %Graph{
      resource: Example,
      nodes: [
        %Node{id: :a, kind: :manual, initial?: true},
        %Node{
          id: :z,
          kind: :terminal,
          notes: [%Note{kind: :policy, label: "actor.role == :admin"}]
        }
      ],
      edges: [%Edge{from: :a, to: :z, kind: :transition, name: :close, label: "close"}]
    }

    assert graph |> D2.render([]) |> IO.iodata_to_binary() =~
             ~S(step_z: "z\n—\npolicy: actor.role == :admin" {class: done})
  end

  test "shows a timeout's own retry policy in its note" do
    assert render(AshWorkflowTest.RetryWorkflow) =~
             ~S(\n—\n⏱ after 2 days: send_nudge, retry: 2 attempts, 30 seconds apart")
  end

  test "prefixes keys, so a step named after a D2 keyword still parses" do
    assert render(AshWorkflowTest.ChartKeywordWorkflow) =~ "step_note -> step_end: \"close\"\n"
  end

  test "quotes a key with a character outside A-Z, a-z, 0-9 and _" do
    output = special_graph() |> D2.render([]) |> IO.iodata_to_binary()

    assert output =~ ~S("step_re-open": "re-open\n✋ manual")
    assert output =~ ~S(step_re_2Dopen: "re_2Dopen\n✋ manual")
    assert output =~ ~S("step_a.b": "a.b" {class: done})
    assert output =~ ~S("step_re-open" -> "step_a.b": )
  end

  test "raises for step names that differ only in case, as D2 keys ignore case" do
    assert_raise ArgumentError,
                 "these step names map to the same D2 key, because D2 keys ignore case: " <>
                   "[:Approved, :approved] -> step_approved",
                 fn -> :Approved |> two_steps(:approved) |> D2.render([]) end
  end

  test "writes a character outside ASCII, or a ~, as its code point in a key" do
    output = :σ |> two_steps(:"ς~") |> D2.render([]) |> IO.iodata_to_binary()

    assert output =~ ~S("step_~3c3~": "σ\n✋ manual")
    assert output =~ ~S("step_~3c2~~7e~": "ς~" {class: done})
    assert output =~ ~S("step_~3c3~" -> "step_~3c2~~7e~": "go")

    assert :É |> two_steps(:é) |> D2.render([]) |> IO.iodata_to_binary() =~
             ~S("step_~c9~" -> "step_~e9~": "go")
  end

  test "escapes quotes, backslashes and $ in labels" do
    output = special_graph() |> D2.render([]) |> IO.iodata_to_binary()

    assert output =~ ~S("go when x == \"a\\b\${c}\"")
  end

  test "direction and layout select the D2 settings" do
    graph = Graph.build(AshWorkflowTest.FullPipeline)
    source = graph |> D2.render(direction: :right, layout: :dagre) |> IO.iodata_to_binary()

    assert source =~ "layout-engine: dagre\n"
    assert source =~ "direction: right\n"
    assert graph |> D2.render(layout: nil) |> IO.iodata_to_binary() =~ "layout-engine: elk\n"
    assert_raise ArgumentError, ~r/direction must be/, fn -> D2.render(graph, direction: :up) end
    assert_raise ArgumentError, ~r/layout must be/, fn -> D2.render(graph, layout: :tala) end
  end

  describe "classes" do
    test "merge over the defaults, class by class and key by key" do
      source =
        AshWorkflowTest.FullPipeline
        |> Graph.build()
        |> D2.render(
          classes: [manual: [fill: "#FFE4E6"], undo: ["stroke-dash": 4, "stroke-width": 2]]
        )
        |> IO.iodata_to_binary()

      assert source =~
               ~S(  manual: {style: {fill: "#FFE4E6"; stroke: "#B7791F"; border-radius: 4}})

      assert source =~ ~S(  undo: {style: {stroke: "#6B7280"; stroke-dash: 4; stroke-width: 2}})

      assert source =~
               ~S(  automatic: {style: {fill: "#E8F0FE"; stroke: "#1A56DB"; border-radius: 4}})
    end

    test "default_classes/0 names every class a shape can use" do
      source = render(AshWorkflowTest.FullPipeline)

      for {class, _style} <- D2.default_classes() do
        assert source =~ "\n  #{class}: {style: {"
      end

      assert Keyword.keys(D2.default_classes()) ==
               [
                 :automatic,
                 :manual,
                 :wait_state,
                 :done,
                 :failed,
                 :expired,
                 :end,
                 :on_success,
                 :on_error,
                 :timeout,
                 :undo
               ]
    end

    test "theme: :dark selects D2's dark theme and the dark classes" do
      source =
        AshWorkflowTest.FullPipeline
        |> Graph.build()
        |> D2.render(theme: :dark)
        |> IO.iodata_to_binary()

      assert source =~ "    theme-id: 200\n"

      assert source =~
               ~S(  manual: {style: {fill: "#78350F"; stroke: "#FCD34D"; font-color: "#F8FAFC"; border-radius: 4}})

      assert source =~ ~S(step_review: "review\n✋ manual)

      assert_raise ArgumentError, ~r/theme must be :light or :dark/, fn ->
        AshWorkflowTest.FullPipeline |> Graph.build() |> D2.render(theme: :sepia)
      end
    end

    test "default_classes/1 has the same classes and keys for both themes" do
      assert Keyword.keys(D2.default_classes(:dark)) == Keyword.keys(D2.default_classes(:light))

      for {class, light} <- D2.default_classes(:light) do
        dark = D2.default_classes(:dark)[class]

        assert Keyword.keys(light) -- Keyword.keys(dark) == [],
               "#{class} loses a key in the dark theme"
      end
    end

    test "a malformed classes value raises with the reason" do
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      for {classes, message} <- [
            {%{manual: [fill: "#FFFFFF"]}, ~r/must be a keyword list/},
            {[manual: "#FFFFFF"], ~r/must be a keyword list/},
            {[manual: [fill: nil]],
             ~r/fill under :manual must be a string, a number or a boolean/},
            {[manual: [{"fill}; x", "#FFFFFF"}]], ~r/is not a D2 style key/},
            {[manual: [bogus: 1]], ~r/"bogus" under :manual is not a D2 style key/},
            {[manual: [shape: "circle"]], ~r/"shape" under :manual is not a D2 style key/},
            {[manual: [:fill]], ~r/is not a style key and value/}
          ] do
        assert_raise ArgumentError, message, fn -> D2.render(graph, classes: classes) end
      end
    end

    test "keyed by theme, only the entry for the current theme applies" do
      graph = Graph.build(AshWorkflowTest.FullPipeline)
      classes = [light: [manual: [fill: "#FFE4E6"]], dark: [manual: [fill: "#881337"]]]

      light = graph |> D2.render(classes: classes) |> IO.iodata_to_binary()
      dark = graph |> D2.render(classes: classes, theme: :dark) |> IO.iodata_to_binary()

      assert light =~
               ~S(  manual: {style: {fill: "#FFE4E6"; stroke: "#B7791F"; border-radius: 4}})

      assert dark =~
               ~S(  manual: {style: {fill: "#881337"; stroke: "#FCD34D"; font-color: "#F8FAFC"; border-radius: 4}})
    end

    test "a theme with no entry keeps its defaults" do
      source =
        AshWorkflowTest.FullPipeline
        |> Graph.build()
        |> D2.render(classes: [dark: [manual: [fill: "#881337"]]])
        |> IO.iodata_to_binary()

      assert source =~
               ~S(  manual: {style: {fill: "#FFF4E5"; stroke: "#B7791F"; border-radius: 4}})
    end

    test "a plain list of classes applies to the dark theme too" do
      source =
        AshWorkflowTest.FullPipeline
        |> Graph.build()
        |> D2.render(classes: [manual: [fill: "#881337"]], theme: :dark)
        |> IO.iodata_to_binary()

      assert source =~
               ~S(  manual: {style: {fill: "#881337"; stroke: "#FCD34D"; font-color: "#F8FAFC"; border-radius: 4}})
    end

    test "a list that mixes theme keys and class names raises" do
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      assert_raise ArgumentError, ~r/the :classes option must be .* not a mix of both/, fn ->
        D2.render(graph, classes: [dark: [manual: [fill: "#881337"]], manual: [fill: "#FFE4E6"]])
      end
    end

    test "the entry for the other theme is checked too" do
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      assert_raise ArgumentError,
                   ~r/the :classes option \(:dark\): unknown D2 class :bogus/,
                   fn ->
                     D2.render(graph, classes: [dark: [bogus: [fill: "#000000"]]])
                   end
    end

    test "a float with no fraction goes in as an integer, and any other float as a decimal" do
      source =
        AshWorkflowTest.FullPipeline
        |> Graph.build()
        |> D2.render(
          classes: [
            on_success: ["stroke-width": 2.0, opacity: 0.5],
            undo: ["stroke-dash": 4.0, opacity: 0.0001]
          ]
        )
        |> IO.iodata_to_binary()

      assert source =~
               ~S(  on_success: {style: {stroke: "#1A56DB"; stroke-width: 2; opacity: 0.5}})

      assert source =~ ~S(  undo: {style: {stroke: "#6B7280"; stroke-dash: 4; opacity: 0.0001}})
    end

    test "for a key given twice in a class, the last value wins" do
      source =
        AshWorkflowTest.FullPipeline
        |> Graph.build()
        |> D2.render(
          classes: [manual: [fill: "#111111", fill: "#222222", opacity: 0.5, opacity: 0.6]]
        )
        |> IO.iodata_to_binary()

      assert source =~
               ~S(  manual: {style: {fill: "#222222"; stroke: "#B7791F"; border-radius: 4; opacity: 0.6}})
    end

    test "a string style key works as an atom does" do
      source =
        AshWorkflowTest.FullPipeline
        |> Graph.build()
        |> D2.render(classes: [undo: [{"stroke-dash", 6}]])
        |> IO.iodata_to_binary()

      assert source =~ ~S(  undo: {style: {stroke: "#6B7280"; stroke-dash: 6}})
    end

    test "takes every D2 style keyword, also one that is not an Elixir name, such as 3d" do
      source =
        AshWorkflowTest.FullPipeline
        |> Graph.build()
        |> D2.render(classes: [automatic: ["3d": true]])
        |> IO.iodata_to_binary()

      assert source =~ ~S(border-radius: 4; 3d: true}})
    end

    test "an unknown class raises" do
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      assert_raise ArgumentError, ~r/unknown D2 class :bogus/, fn ->
        D2.render(graph, classes: [bogus: [fill: "#000000"]])
      end
    end
  end

  test "takes only the svg, direction, layout, theme and classes options" do
    graph = Graph.build(AshWorkflowTest.FullPipeline)

    assert_raise ArgumentError, fn -> D2.render(graph, pretty: true) end
  end

  test "writes .d2 files" do
    assert D2.file_extension() == "d2"
  end

  # These run the downloaded `d2`, through `AshWorkflow.Charts.D2.Binary`.
  describe "svg: true" do
    @describetag :d2

    test "returns the SVG that d2 draws for every fixture workflow" do
      for resource <- @fixtures do
        svg = resource |> Graph.build() |> D2.render(svg: true)

        assert svg =~ "<svg", "d2 gave no SVG for #{inspect(resource)}"
      end
    end

    test "gives the SVG its own width and height, so an img tag shows it at full size" do
      svg = AshWorkflowTest.FullPipeline |> Graph.build() |> D2.render(svg: true)
      [root] = Regex.run(~r/<svg [^>]*>/, svg)

      assert root =~ ~r/ width="\d+"/
      assert root =~ ~r/ height="\d+"/
    end

    test "draws a chart with float style values" do
      svg =
        AshWorkflowTest.FullPipeline
        |> Graph.build()
        |> D2.render(
          svg: true,
          classes: [manual: ["font-size": 14.0, opacity: 0.0001], undo: ["stroke-width": 2.0]]
        )

      assert svg =~ "<svg"
    end

    test "keeps the labels, with special characters, in the SVG" do
      svg = special_graph() |> D2.render(svg: true)

      assert svg =~ "re-open"
      assert svg =~ "a.b"
      assert svg =~ ~S(go when x == &#34;a\b${c}&#34;)
    end
  end

  # Step names with `-` and `.`, a name that differs from one of them only by
  # punctuation, and a condition with `"`, `\` and `${`.
  defp special_graph do
    %Graph{
      resource: Example,
      nodes: [
        %Node{id: :"re-open", kind: :manual, initial?: true},
        %Node{id: :re_2Dopen, kind: :manual},
        %Node{id: :"a.b", kind: :terminal}
      ],
      edges: [
        %Edge{
          from: :"re-open",
          to: :"a.b",
          kind: :transition,
          name: :go,
          label: "go",
          condition: ~S(x == "a\b${c}")
        },
        %Edge{from: :re_2Dopen, to: :"a.b", kind: :transition, name: :close, label: "close"}
      ]
    }
  end

  defp two_steps(first, second) do
    %Graph{
      resource: Example,
      nodes: [
        %Node{id: first, kind: :manual, initial?: true},
        %Node{id: second, kind: :terminal}
      ],
      edges: [%Edge{from: first, to: second, kind: :transition, name: :go, label: "go"}]
    }
  end

  defp render(resource) do
    resource |> Graph.build() |> D2.render([]) |> IO.iodata_to_binary()
  end
end
