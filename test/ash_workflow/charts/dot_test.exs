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
             "step_investigating" -> "step_escalated" [label="↶ undo within 1 hour", dir="back", color="#6B7280", style="dotted", arrowtail="onormal"];
             "step_investigating" -> "step_resolved" [label="↶ undo within 1 hour", dir="back", color="#6B7280", style="dotted", arrowtail="onormal"];
             "step_escalated" -> "step_resolved" [label="↶ undo within 1 hour", dir="back", color="#6B7280", style="dotted", arrowtail="onormal"];
           }
           """
  end

  test "draws a wait state with a dashed border" do
    assert render(AshWorkflowTest.WaitStateWorkflow) =~
             ~S("step_queued" [label="queued\n⏳ wait state", fillcolor="#F3E8FF", color="#6B46C1", fontcolor="#0A0F25", style="rounded,filled,dashed"];)
  end

  test "draws a timeout dashed, and an undo dotted from the earlier step" do
    assert render(AshWorkflowTest.FullPipeline) =~
             ~S("step_review" -> "step_escalated" [label="⏱ escalation after 7 days", color="#B45309", style="dashed"];)

    assert render(AshWorkflowTest.UndoWorkflow) =~
             ~S("step_review" -> "step_publish" [label="↶ undo within 1 hour", dir="back", color="#6B7280", style="dotted", arrowtail="onormal"];)
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

  test "keeps a step name outside ASCII as it is, as DOT IDs are case-sensitive" do
    output = :É |> two_steps(:é) |> Dot.render([]) |> IO.iodata_to_binary()

    assert output =~ ~S("step_É" [label="É\n✋ manual")
    assert output =~ ~S("step_É" -> "step_é" [label="go"];)
  end

  test "escapes quotes and backslashes in labels" do
    output = special_graph() |> Dot.render([]) |> IO.iodata_to_binary()

    assert output =~ ~S([label="go when x == \"a\\b\\N\""])
  end

  test "writes & as &amp; in a label, as Graphviz reads an HTML entity as its character" do
    output = entity_graph() |> Dot.render([]) |> IO.iodata_to_binary()

    assert output =~ ~S("step_R&amp;D" [label="R&amp;amp;D\n✋ manual")
    assert output =~ ~S("step_R&amp;D" -> "step_done" [label="go when team == \"R&amp;amp;D\""];)
  end

  test "direction selects the rank direction" do
    graph = Graph.build(AshWorkflowTest.FullPipeline)

    assert graph |> Dot.render(direction: :right) |> IO.iodata_to_binary() =~
             "  graph [rankdir=LR, "

    assert graph |> Dot.render(direction: nil) |> IO.iodata_to_binary() =~
             "  graph [rankdir=TB, "

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
               ~S(color="#6B7280", style="dashed", arrowtail="onormal", penwidth=2];)

      assert source =~ ~S(fillcolor="#E8F0FE", color="#1A56DB")
    end

    test "for a key given twice in a class, the last value wins" do
      source =
        AshWorkflowTest.UndoWorkflow
        |> Graph.build()
        |> Dot.render(
          classes: [
            manual: [fillcolor: "#111111", fillcolor: "#222222", penwidth: 1, penwidth: 2]
          ]
        )
        |> IO.iodata_to_binary()

      assert source =~
               ~S("step_review" [label="review\n✋ manual", fillcolor="#222222", color="#B7791F", fontcolor="#0A0F25", style="rounded,filled", penwidth=2];)
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

      assert source =~ ~S(arrowtail="onormal", penwidth=0.5, constraint=false, weight=2];)
    end

    test "takes every node and edge attribute, also one in capitals, such as URL" do
      source =
        AshWorkflowTest.FullPipeline
        |> Graph.build()
        |> Dot.render(
          classes: [automatic: [URL: "https://example.com"], on_error: [headURL: "#u"]]
        )
        |> IO.iodata_to_binary()

      assert source =~ ~S(style="rounded,filled", URL="https://example.com"];)
      assert source =~ ~S(color="#C81E1E", headURL="#u"];)
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
            {[manual: [bogus: 1]], ~r/"bogus" under :manual is not a DOT attribute name/},
            {[manual: [rankdir: "LR"]], ~r/"rankdir" under :manual is not a DOT attribute name/},
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

    test "keyed by theme, only the entry for the current theme applies" do
      classes = [light: [manual: [fillcolor: "#FFE4E6"]], dark: [manual: [fillcolor: "#881337"]]]

      assert render(AshWorkflowTest.FullPipeline, classes: classes) =~
               ~S("step_on_hold" [label="on_hold\n✋ manual\n—\npolicy: actor.role == :reviewer", fillcolor="#FFE4E6", color="#B7791F", fontcolor="#0A0F25", style="rounded,filled"];)

      assert render(AshWorkflowTest.FullPipeline, classes: classes, theme: :dark) =~
               ~S("step_on_hold" [label="on_hold\n✋ manual\n—\npolicy: actor.role == :reviewer", fillcolor="#881337", color="#FCD34D", fontcolor="#F8FAFC", style="rounded,filled"];)
    end

    test "a theme given twice applies both entries, and the later one wins key by key" do
      classes = [
        light: [manual: [fillcolor: "#111111", penwidth: 1]],
        dark: [manual: [fillcolor: "#881337"]],
        light: [manual: [fillcolor: "#222222"]]
      ]

      assert render(AshWorkflowTest.FullPipeline, classes: classes) =~
               ~S(fillcolor="#222222", color="#B7791F", fontcolor="#0A0F25", style="rounded,filled", penwidth=1];)
    end

    test "a theme with no entry keeps its defaults" do
      assert render(AshWorkflowTest.FullPipeline,
               classes: [dark: [manual: [fillcolor: "#881337"]]]
             ) =~
               ~S(fillcolor="#FFF4E5", color="#B7791F", fontcolor="#0A0F25", style="rounded,filled"];)
    end

    test "a plain list of classes applies to the dark theme too" do
      assert render(AshWorkflowTest.FullPipeline,
               classes: [manual: [fillcolor: "#881337"]],
               theme: :dark
             ) =~
               ~S(fillcolor="#881337", color="#FCD34D", fontcolor="#F8FAFC", style="rounded,filled"];)
    end

    test "a list that mixes theme keys and class names raises" do
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      assert_raise ArgumentError, ~r/the :classes option must be .* not a mix of both/, fn ->
        Dot.render(graph,
          classes: [dark: [manual: [fillcolor: "#881337"]], manual: [fillcolor: "#FFE4E6"]]
        )
      end
    end

    test "the entry for the other theme is checked too" do
      graph = Graph.build(AshWorkflowTest.FullPipeline)

      assert_raise ArgumentError,
                   ~r/the :classes option \(:dark\): unknown DOT class :bogus/,
                   fn ->
                     Dot.render(graph, classes: [dark: [bogus: [fillcolor: "#000000"]]])
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

    test "draws step names outside ASCII, and names that differ only in case, apart" do
      for {first, second} <- [{:σ, :ς}, {:É, :é}, {:Approved, :approved}] do
        svg = first |> two_steps(second) |> Dot.render(svg: true)

        assert svg =~ ~s(<title>step_#{first}</title>)
        assert svg =~ ~s(<title>step_#{second}</title>)
        assert svg =~ ~s(<title>step_#{first}&#45;&gt;step_#{second}</title>)
      end
    end

    test "keeps the labels, with special characters, in the SVG" do
      svg = special_graph() |> Dot.render(svg: true)

      # Graphviz writes `-` as `&#45;`, and `\N` stays as text.
      assert svg =~ "re&#45;open"
      assert svg =~ "a.b"
      assert svg =~ ~S(go when x == &quot;a\b\N&quot;)
    end

    test "shows an HTML entity in a label as text" do
      svg = entity_graph() |> Dot.render(svg: true)

      # The XML for the text `R&amp;D`.
      assert svg =~ ">R&amp;amp;D</text>"
    end

    @tag :tmp_dir
    test "an undo edge does not turn a forward edge upward", %{tmp_dir: dir} do
      input = Path.join(dir, "undo.dot")
      File.write!(input, render(AshWorkflowTest.UndoWorkflow))
      {plain, 0} = System.cmd(Dot.executable(), ["-Tplain", input])

      # `-Tplain` writes a line `node <name> <x> <y> ...` for each node, and
      # y grows upward.
      y =
        for "node " <> node <- String.split(plain, "\n"), into: %{} do
          [name, _x, y | _rest] = String.split(node, " ")
          {name, y |> Float.parse() |> elem(0)}
        end

      # `deferred -> publish` is a forward edge, and the step `deferred` can
      # undo it.
      assert y["step_deferred"] > y["step_publish"]
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

  # A step name and a condition with `&amp;`, which Graphviz would read as
  # `&`.
  defp entity_graph do
    %Graph{
      resource: Example,
      nodes: [
        %Node{id: :"R&amp;D", kind: :manual, initial?: true},
        %Node{id: :done, kind: :terminal}
      ],
      edges: [
        %Edge{
          from: :"R&amp;D",
          to: :done,
          kind: :transition,
          name: :go,
          label: "go",
          condition: ~S(team == "R&amp;D")
        }
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

  defp render(resource, opts \\ []) do
    resource |> Graph.build() |> Dot.render(opts) |> IO.iodata_to_binary()
  end
end

defmodule AshWorkflow.Charts.DotConfigTest do
  # These tests change the application environment, so they run alone.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshWorkflow.Charts.Dot
  alias AshWorkflow.Charts.Graph

  require Logger

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

  test ":classes keyed by theme applies only the entry for the current theme" do
    Application.put_env(:ash_workflow, :dot,
      classes: [light: [manual: [fillcolor: "#FFE4E6"]], dark: [manual: [fillcolor: "#881337"]]]
    )

    graph = Graph.build(AshWorkflowTest.FullPipeline)

    assert graph |> Dot.render([]) |> IO.iodata_to_binary() =~
             ~S(fillcolor="#FFE4E6", color="#B7791F", fontcolor="#0A0F25", style="rounded,filled"];)

    assert graph |> Dot.render(theme: :dark) |> IO.iodata_to_binary() =~
             ~S(fillcolor="#881337", color="#FCD34D", fontcolor="#F8FAFC", style="rounded,filled"];)
  end

  test "malformed :classes in the config raises and names the config" do
    Application.put_env(:ash_workflow, :dot, classes: [manual: "#FFFFFF"])

    assert_raise ArgumentError, ~r/config :ash_workflow, :dot, classes: must be/, fn ->
      AshWorkflowTest.FullPipeline |> Graph.build() |> Dot.render([])
    end
  end

  test "a nil :theme or :classes is the same as no key" do
    Application.put_env(:ash_workflow, :dot, theme: nil, classes: nil)
    graph = Graph.build(AshWorkflowTest.FullPipeline)

    assert Dot.theme() == :light

    assert graph |> Dot.render(theme: nil, classes: nil) |> IO.iodata_to_binary() =~
             ~S(bgcolor="#FFFFFF")
  end

  test ":theme sets the theme for every chart, and the option overrides it" do
    Application.put_env(:ash_workflow, :dot, theme: :dark)
    graph = Graph.build(AshWorkflowTest.FullPipeline)

    assert Dot.theme() == :dark
    assert Dot.theme(theme: :light) == :light
    assert graph |> Dot.render([]) |> IO.iodata_to_binary() =~ ~S(bgcolor="#1E1E2E")
    assert graph |> Dot.render(theme: :light) |> IO.iodata_to_binary() =~ ~S(bgcolor="#FFFFFF")
  end

  test ":path may name a file or a command on the PATH" do
    Application.put_env(:ash_workflow, :dot, path: "sh")
    assert Dot.executable() == System.find_executable("sh")

    Application.put_env(:ash_workflow, :dot, path: System.find_executable("sh"))
    assert Dot.executable() == System.find_executable("sh")
  end

  test "a nil or empty :path is the same as no :path" do
    for path <- [nil, ""] do
      Application.put_env(:ash_workflow, :dot, path: path)

      assert Dot.executable() == System.find_executable("dot")
    end
  end

  test "a :path that is not a string raises" do
    for path <- [false, ~c"/usr/bin/dot", :dot] do
      Application.put_env(:ash_workflow, :dot, path: path)

      assert_raise ArgumentError,
                   "config :ash_workflow, :dot, path: must be a string, got: #{inspect(path)}",
                   fn -> Dot.executable() end
    end
  end

  test "a :dot config that is not a keyword list raises and names the config" do
    Application.put_env(:ash_workflow, :dot, "/usr/bin/dot")

    assert_raise ArgumentError,
                 ~S(config :ash_workflow, :dot must be a keyword list, such as [theme: :dark, path: "/usr/bin/dot"], got: "/usr/bin/dot"),
                 fn -> Dot.theme() end
  end

  test "a nil :dot config is the same as no config" do
    Application.put_env(:ash_workflow, :dot, nil)

    assert Dot.theme() == :light
    assert Dot.executable() == System.find_executable("dot")
  end

  @tag :tmp_dir
  test "a :path that starts with ~ is in the home directory", %{tmp_dir: dir} do
    script = script!(dir, "dot", "exit 0")
    home_relative = Path.relative_to(script, System.user_home!(), force: true)
    Application.put_env(:ash_workflow, :dot, path: "~/" <> home_relative)

    assert Dot.executable() == script
  end

  @tag :tmp_dir
  test "a relative :path to a file is made absolute, as System.cmd/3 looks for it on the PATH",
       %{tmp_dir: dir} do
    script = script!(dir, "dot", "exit 0")
    Application.put_env(:ash_workflow, :dot, path: Path.relative_to_cwd(script))

    assert Dot.executable() == script
  end

  test "a :path with no / is a command on the PATH, not a file in the current directory" do
    Application.put_env(:ash_workflow, :dot, path: "mix.exs")

    assert Dot.executable() == nil
  end

  test "a :path to a file that is not executable names no dot" do
    Application.put_env(:ash_workflow, :dot, path: "./mix.exs")

    assert Dot.executable() == nil
  end

  test "a :path that names no dot raises an error that names Graphviz" do
    Application.put_env(:ash_workflow, :dot, path: "no-such-dot-command")

    assert Dot.executable() == nil

    assert_raise ArgumentError,
                 ~r/sets :path to "no-such-dot-command", which is neither an executable file nor a command on the PATH. Install Graphviz/,
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
    failing = script!(dir, "dot", "echo 'Error: syntax error in line 1' >&2\nexit 1")
    Application.put_env(:ash_workflow, :dot, path: failing)

    assert_raise ArgumentError, "dot rejected the diagram: Error: syntax error in line 1", fn ->
      AshWorkflowTest.FullPipeline |> Graph.build() |> Dot.render(svg: true)
    end
  end

  @tag :tmp_dir
  test "a dot that fails and prints nothing gets a message with its exit status",
       %{tmp_dir: dir} do
    silent = script!(dir, "silent", "exit 3")
    Application.put_env(:ash_workflow, :dot, path: silent)

    assert_raise ArgumentError,
                 "dot rejected the diagram: #{silent} exited with status 3 and printed nothing",
                 fn -> AshWorkflowTest.FullPipeline |> Graph.build() |> Dot.render(svg: true) end
  end

  @tag :tmp_dir
  test "a dot that exits with status 0 and writes no SVG raises", %{tmp_dir: dir} do
    graph = Graph.build(AshWorkflowTest.FullPipeline)
    empty = script!(dir, "empty", "exit 0")
    Application.put_env(:ash_workflow, :dot, path: empty)

    assert_raise ArgumentError,
                 "dot rejected the diagram: #{empty} exited with status 0 and wrote no SVG",
                 fn -> Dot.render(graph, svg: true) end

    talking = script!(dir, "talking", "echo 'Warning: no output' >&2")
    Application.put_env(:ash_workflow, :dot, path: talking)

    assert_raise ArgumentError,
                 "dot rejected the diagram: #{talking} exited with status 0 and wrote no SVG: " <>
                   "Warning: no output",
                 fn -> Dot.render(graph, svg: true) end
  end

  describe "a message from a dot that draws the chart" do
    # The test config logs only critical messages.
    setup do
      Logger.put_module_level(Dot, :warning)
      on_exit(fn -> Logger.delete_module_level(Dot) end)
    end

    @tag :tmp_dir
    test "goes to the log", %{tmp_dir: dir} do
      # `dot -Tsvg -o <output> <input>`, so the output file is `$3`.
      warning =
        script!(dir, "dot", ~S"""
        echo '<svg/>' > "$3"
        echo 'Warning: notacolour is not a known color.' >&2
        """)

      Application.put_env(:ash_workflow, :dot, path: warning)

      log =
        capture_log(fn ->
          assert AshWorkflowTest.FullPipeline |> Graph.build() |> Dot.render(svg: true) ==
                   "<svg/>\n"
        end)

      assert log =~
               "dot printed a message while it drew the chart: " <>
                 "Warning: notacolour is not a known color."
    end

    @tag :dot
    test "goes to the log with the real dot" do
      log =
        capture_log(fn ->
          AshWorkflowTest.FullPipeline
          |> Graph.build()
          |> Dot.render(svg: true, classes: [manual: [fillcolor: "notacolour"]])
        end)

      assert log =~ "Warning: notacolour is not a known color."
    end
  end

  # An executable shell script with the given body.
  defp script!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end

  defp restore(nil), do: Application.delete_env(:ash_workflow, :dot)
  defp restore(previous), do: Application.put_env(:ash_workflow, :dot, previous)
end
