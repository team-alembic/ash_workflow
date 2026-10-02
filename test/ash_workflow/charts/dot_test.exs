defmodule AshWorkflow.Charts.DotTest do
  use ExUnit.Case, async: true

  alias AshWorkflow.Charts.Dot
  alias AshWorkflow.Charts.Graph
  alias AshWorkflow.Charts.Graph.Edge
  alias AshWorkflow.Charts.Graph.Node
  alias AshWorkflow.Charts.Graph.Note
  alias AshWorkflow.Charts.Palette

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

  test "draws the incident workflow" do
    assert render(BasicWorkflow.Incident) == ~S"""
           digraph "BasicWorkflow.Incident" {
             graph [rankdir=TB, bgcolor="#FFFFFF", fontname="Helvetica", pad=0.3, nodesep=0.5, ranksep=0.6];
             node [shape=box, fontname="Helvetica", fontsize=14, margin="0.2,0.1", penwidth=2];
             edge [fontname="Helvetica", fontsize=12, fontcolor="#0A0F25", color="#0A0F25", penwidth=1.5];
             "start" [shape=circle, label="", width=0.2, style=filled, fillcolor="#0A0F25", color="#0A0F25"];
             "step_triaging" [label="triaging\n⚙️ automatic", fillcolor="#E8F0FE", color="#1A56DB", fontcolor="#0A0F25", style="rounded,filled"];
             "step_investigating" [label="investigating\n✋ manual\n—\n↻ every 1 hour: send_status_update", fillcolor="#FFF4E5", color="#B7791F", fontcolor="#0A0F25", style="rounded,filled"];
             "step_escalated" [label="escalated\n✋ manual", fillcolor="#FFF4E5", color="#B7791F", fontcolor="#0A0F25", style="rounded,filled"];
             "step_resolved" [label="resolved", fillcolor="#E6F4EA", color="#1E7B34", fontcolor="#0A0F25", style="filled", peripheries=2];
             "step_triage_failed" [label="triage_failed", fillcolor="#FDE8E8", color="#C81E1E", fontcolor="#0A0F25", style="filled", peripheries=2];
             "start" -> "step_triaging";
             "step_triaging" -> "step_investigating" [label="⚙ classify_severity", color="#1A56DB", penwidth=3];
             "step_triaging" -> "step_triage_failed" [label="✖ on_error", color="#C81E1E"];
             "step_investigating" -> "step_escalated" [label="escalate"];
             "step_investigating" -> "step_resolved" [label="resolve"];
             "step_investigating" -> "step_escalated" [label="⏱ auto_escalate after 4 hours", color="#B45309", style="dashed"];
             "step_escalated" -> "step_resolved" [label="resolve"];
             "step_escalated" -> "step_investigating" [label="↶ undo within 1 hour", color="#6B7280", style="dotted", arrowhead="vee"];
             "step_resolved" -> "step_investigating" [label="↶ undo within 1 hour", color="#6B7280", style="dotted", arrowhead="vee"];
             "step_resolved" -> "step_escalated" [label="↶ undo within 1 hour", color="#6B7280", style="dotted", arrowhead="vee"];
           }
           """
  end

  test "draws a wait state with a dashed border" do
    assert render(AshWorkflowTest.WaitStateWorkflow) =~
             ~S("step_queued" [label="queued\n⏳ wait state", fillcolor="#F3E8FF", color="#6B46C1", fontcolor="#0A0F25", style="rounded,filled,dashed"];)
  end

  test "draws a timeout dashed and an undo dotted" do
    assert render(AshWorkflowTest.FullPipeline) =~
             ~S("step_review" -> "step_escalated" [label="⏱ escalation after 7 days", color="#B45309", style="dashed"];)

    assert render(AshWorkflowTest.UndoWorkflow) =~
             ~S("step_publish" -> "step_review" [label="↶ undo within 1 hour", color="#6B7280", style="dotted", arrowhead="vee"];)
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

    assert graph |> Dot.render([]) |> IO.iodata_to_binary() =~
             ~S("step_z" [label="z\n—\npolicy: actor.role == :admin", fillcolor="#E6F4EA")
  end

  test "quotes every ID, so a step named after a DOT keyword still parses" do
    output = render(AshWorkflowTest.ChartKeywordWorkflow)

    assert output =~ ~S("step_note" [label="note\n✋ manual")
    assert output =~ ~S("step_note" -> "step_end" [label="close"];)
  end

  test "quotes an ID with a character outside A-Z, a-z, 0-9 and _" do
    output = special_graph() |> Dot.render([]) |> IO.iodata_to_binary()

    assert output =~ ~S("step_re-open" [label="re-open\n✋ manual")
    assert output =~ ~S("step_a.b" [label="a.b")
    assert output =~ ~S("step_re-open" -> "step_a.b" )
  end

  test "escapes quotes and backslashes in labels" do
    output = special_graph() |> Dot.render([]) |> IO.iodata_to_binary()

    assert output =~ ~S([label="go when x == \"a\\b\\N\""])
  end

  test "direction selects the rank direction" do
    graph = Graph.build(AshWorkflowTest.FullPipeline)

    assert graph |> Dot.render(direction: :right) |> IO.iodata_to_binary() =~
             "  graph [rankdir=LR, "

    assert_raise ArgumentError, ~r/direction must be/, fn -> Dot.render(graph, direction: :up) end
  end

  describe "classes" do
    test "merge over the defaults, class by class and key by key" do
      source =
        AshWorkflowTest.UndoWorkflow
        |> Graph.build()
        |> Dot.render(
          classes: [manual: [fillcolor: "#FFE4E6"], undo: [style: "dashed", penwidth: 2]]
        )
        |> IO.iodata_to_binary()

      assert source =~
               ~S("step_review" [label="review\n✋ manual", fillcolor="#FFE4E6", color="#B7791F", fontcolor="#0A0F25", style="rounded,filled"];)

      assert source =~
               ~S(color="#6B7280", style="dashed", arrowhead="vee", penwidth=2];)

      assert source =~ ~S(fillcolor="#E8F0FE", color="#1A56DB")
    end

    test "default_classes/0 has a class for each step kind, terminal outcome and edge kind" do
      assert Keyword.keys(Dot.default_classes()) ==
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

      assert Dot.default_classes()[:done] == [
               fillcolor: "#E6F4EA",
               color: "#1E7B34",
               fontcolor: "#0A0F25",
               style: "filled",
               peripheries: 2
             ]

      assert Dot.default_classes()[:on_success] == [color: "#1A56DB", penwidth: 3]
    end

    test "theme: :dark selects the dark background and the dark classes" do
      source =
        AshWorkflowTest.FullPipeline
        |> Graph.build()
        |> Dot.render(theme: :dark)
        |> IO.iodata_to_binary()

      assert source =~ ~S(bgcolor="#1E1E2E")

      assert source =~
               ~S(edge [fontname="Helvetica", fontsize=12, fontcolor="#F8FAFC", color="#F8FAFC")

      assert source =~
               ~S("step_on_hold" [label="on_hold\n✋ manual\n—\npolicy: actor.role == :reviewer", fillcolor="#78350F", color="#FCD34D", fontcolor="#F8FAFC", style="rounded,filled"];)

      assert_raise ArgumentError, ~r/theme must be :light or :dark/, fn ->
        AshWorkflowTest.FullPipeline |> Graph.build() |> Dot.render(theme: :sepia)
      end
    end

    test "default_classes/1 has the same classes and keys for both themes" do
      for {class, light} <- Dot.default_classes(:light) do
        assert Keyword.keys(Dot.default_classes(:dark)[class]) == Keyword.keys(light)
      end
    end

    test "writes a string quoted, and a number or a boolean bare" do
      source =
        AshWorkflowTest.UndoWorkflow
        |> Graph.build()
        |> Dot.render(classes: [undo: [{"penwidth", 0.5}, constraint: false, weight: 2]])
        |> IO.iodata_to_binary()

      assert source =~ ~S(arrowhead="vee", penwidth=0.5, constraint=false, weight=2];)
    end

    test "a malformed classes value raises with the reason" do
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      for {classes, message} <- [
            {%{manual: [fillcolor: "#FFFFFF"]}, ~r/must be a keyword list/},
            {[manual: "#FFFFFF"], ~r/must be a keyword list/},
            {[manual: [fillcolor: nil]],
             ~r/fillcolor under :manual must be a string, a number or a boolean/},
            {[manual: [{"fillcolor] x", "#FFFFFF"}]], ~r/is not a DOT attribute name/},
            {[manual: [{"font-color", "#FFFFFF"}]], ~r/is not a DOT attribute name/},
            {[manual: [:fillcolor]], ~r/is not an attribute name and value/}
          ] do
        assert_raise ArgumentError, message, fn -> Dot.render(graph, classes: classes) end
      end
    end

    test "an unknown class raises" do
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      assert_raise ArgumentError, ~r/unknown DOT class :bogus/, fn ->
        Dot.render(graph, classes: [bogus: [fillcolor: "#000000"]])
      end
    end
  end

  test "takes only the svg, direction, theme and classes options" do
    graph = Graph.build(AshWorkflowTest.FullPipeline)

    assert_raise ArgumentError, fn -> Dot.render(graph, layout: :elk) end
  end

  test "writes .dot files" do
    assert Dot.file_extension() == "dot"
  end

  # These run Graphviz's `dot`. The test helper skips them when there is none.
  describe "with dot" do
    @describetag :dot

    @tag :tmp_dir
    # One file holds every chart, because each run of `dot` has a start-up
    # cost. `-O` writes one SVG for each graph in the file, and the messages
    # of `dot` name the nodes.
    test "dot reads every fixture and example workflow with no message", %{tmp_dir: dir} do
      input = Path.join(dir, "charts.dot")

      File.write!(
        input,
        for(resource <- @fixtures, theme <- [:light, :dark], do: render(resource, theme: theme))
      )

      assert System.cmd(Dot.executable(), ["-Tsvg", "-O", input], stderr_to_stdout: true) ==
               {"", 0}

      assert dir |> File.ls!() |> Enum.count(&String.ends_with?(&1, ".svg")) ==
               2 * length(@fixtures)
    end

    test "svg: true returns the SVG, in both themes" do
      for theme <- [:light, :dark] do
        svg = BasicWorkflow.Incident |> Graph.build() |> Dot.render(svg: true, theme: theme)

        assert svg =~ "<svg"
        assert svg =~ ~s(fill="#{String.downcase(Palette.background(theme))}")
      end
    end

    test "gives the SVG its own width and height, so an img tag shows it at full size" do
      svg = AshWorkflowTest.FullPipeline |> Graph.build() |> Dot.render(svg: true)
      [root] = Regex.run(~r/<svg [^>]*>/, svg)

      assert root =~ ~r/ width="\d+pt"/
      assert root =~ ~r/ height="\d+pt"/
    end

    test "keeps the labels, with special characters, in the SVG" do
      svg = special_graph() |> Dot.render(svg: true)

      # Graphviz writes `-` as `&#45;`, and `\N` stays as text.
      assert svg =~ "re&#45;open"
      assert svg =~ "a.b"
      assert svg =~ ~S(go when x == &quot;a\b\N&quot;)
    end
  end

  # Step names with `-` and `.`, a name that differs from one of them only by
  # punctuation, and a condition with `"`, `\` and `\N`, which Graphviz would
  # read as the node name.
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
          condition: ~S(x == "a\b\N")
        },
        %Edge{from: :re_2Dopen, to: :"a.b", kind: :transition, name: :close, label: "close"}
      ]
    }
  end

  defp render(resource, opts \\ []) do
    resource |> Graph.build() |> Dot.render(opts) |> IO.iodata_to_binary()
  end
end

defmodule AshWorkflow.Charts.DotConfigTest do
  # These tests change the application environment, so they run alone.
  use ExUnit.Case, async: false

  alias AshWorkflow.Charts.Dot
  alias AshWorkflow.Charts.Graph

  setup do
    previous = Application.get_env(:ash_workflow, :dot)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  test ":classes applies to every chart, and the option merges over it" do
    Application.put_env(:ash_workflow, :dot, classes: [failed: [fillcolor: "#000000"]])
    graph = Graph.build(AshWorkflowTest.FullPipeline)

    assert graph |> Dot.render([]) |> IO.iodata_to_binary() =~
             ~S("step_intake_failed" [label="intake_failed", fillcolor="#000000", color="#C81E1E")

    assert graph |> Dot.render(classes: [failed: [color: "#FFFFFF"]]) |> IO.iodata_to_binary() =~
             ~S("step_intake_failed" [label="intake_failed", fillcolor="#000000", color="#FFFFFF")
  end

  test "malformed :classes in the config raises and names the config" do
    Application.put_env(:ash_workflow, :dot, classes: [manual: "#FFFFFF"])

    assert_raise ArgumentError, ~r/config :ash_workflow, :dot, classes: must be/, fn ->
      AshWorkflowTest.FullPipeline |> Graph.build() |> Dot.render([])
    end
  end

  test ":theme sets the theme for every chart, and the option overrides it" do
    Application.put_env(:ash_workflow, :dot, theme: :dark)
    graph = Graph.build(AshWorkflowTest.FullPipeline)

    assert graph |> Dot.render([]) |> IO.iodata_to_binary() =~ ~S(bgcolor="#1E1E2E")
    assert graph |> Dot.render(theme: :light) |> IO.iodata_to_binary() =~ ~S(bgcolor="#FFFFFF")
  end

  test ":path may name a file or a command on the PATH" do
    Application.put_env(:ash_workflow, :dot, path: "sh")
    assert Dot.executable() == System.find_executable("sh")

    Application.put_env(:ash_workflow, :dot, path: System.find_executable("sh"))
    assert Dot.executable() == System.find_executable("sh")
  end

  test "a :path that names no dot raises an error that names Graphviz" do
    Application.put_env(:ash_workflow, :dot, path: "no-such-dot-command")

    assert Dot.executable() == nil

    assert_raise ArgumentError,
                 ~r/sets :path to "no-such-dot-command", which is neither a file nor a command on the PATH. Install Graphviz/,
                 fn -> AshWorkflowTest.FullPipeline |> Graph.build() |> Dot.render(svg: true) end
  end

  @tag :dot
  test ":path names the dot to run" do
    Application.put_env(:ash_workflow, :dot, path: "dot")

    assert Dot.executable() == System.find_executable("dot")
    assert AshWorkflowTest.FullPipeline |> Graph.build() |> Dot.render(svg: true) =~ "<svg"
  end

  @tag :tmp_dir
  test "a non-zero exit raises with the message of dot", %{tmp_dir: dir} do
    failing = Path.join(dir, "dot")
    File.write!(failing, "#!/bin/sh\necho 'Error: syntax error in line 1' >&2\nexit 1\n")
    File.chmod!(failing, 0o755)
    Application.put_env(:ash_workflow, :dot, path: failing)

    assert_raise ArgumentError, "dot rejected the diagram: Error: syntax error in line 1", fn ->
      AshWorkflowTest.FullPipeline |> Graph.build() |> Dot.render(svg: true)
    end
  end

  defp restore(nil), do: Application.delete_env(:ash_workflow, :dot)
  defp restore(previous), do: Application.put_env(:ash_workflow, :dot, previous)
end
