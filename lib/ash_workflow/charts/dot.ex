defmodule AshWorkflow.Charts.Dot do
  @moduledoc """
  Draws an `AshWorkflow.Charts.Graph` as a [Graphviz](https://graphviz.org)
  DOT diagram.

  DOT is the text format of Graphviz. Its `dot` command lays a diagram out
  and draws it as SVG, PNG or PDF, and many other tools read DOT. This chart
  shows the same steps, edges and labels as `AshWorkflow.Charts.Mermaid`,
  with colour and line styles added. Use it when Graphviz is already on your
  machines.

      # The DOT source, to keep in the repository or to draw yourself:
      AshWorkflow.Charts.render(MyApp.Candidate, :dot)

      # The SVG. This runs `dot`, which must be installed:
      AshWorkflow.Charts.render(MyApp.Candidate, :dot, svg: true)

  ## What the chart shows

  | In the workflow | In the chart |
  |---|---|
  | Automatic step | Blue box, `⚙\u{FE0F} automatic` under the name |
  | Manual step | Amber box, `✋ manual` under the name |
  | Wait state | Lavender box with a dashed border, `⏳ wait state` under the name |
  | Terminal step | Double border. Green, red, amber or grey: see "Terminal steps" |
  | Initial step | An edge from a small filled circle |
  | `on_success` | Thick blue edge, `⚙` and the action |
  | `on_error` | Red edge, `✖ on_error` |
  | Timeout | Dashed amber edge, `⏱`, the timeout's name and its deadline |
  | Undo | Dotted grey edge with a hollow arrowhead, `↶ undo`, and the window when `within` is set |
  | Transition | Plain edge, the transition's name |
  | Step notes | Under a rule inside the step: `policy:`, `retry:`, `⏱` and `↻` |

  Each edge kind other than a transition has a symbol in its label as well
  as a colour. `on_success`, timeouts and undo also have a line style, and
  `on_error` is a plain red line with `✖`. So a reader who cannot tell the
  colours apart loses nothing. The colours come from
  `AshWorkflow.Charts.Palette`. The label text comes from
  `AshWorkflow.Charts.Format`, so it is the same in every format.

  ## Terminal steps

  The colour of a terminal step comes from the edges that reach it:

  * **Red** when only `on_error` edges reach it.
  * **Amber** when only timeouts reach it.
  * **Green** when only transitions and `on_success` reach it.
  * **Grey** for a mix of these, or for no edge at all.

  This rule reads the edges, not the step's name. A step named `rejected`
  that a person chooses is green, because the workflow reaches it the same
  way as `approved`. The backend cannot know that one outcome is good and the
  other is bad. `AshWorkflow.Charts.Palette.terminal_class/2` gives the class
  of one step.

  ## Layout

  `dot` puts the steps in ranks, from the initial step to the end steps. An
  edge that closes a loop, such as a transition back to an earlier step,
  goes back up the ranks.

  An undo edge goes from a later step to an earlier step. The file writes it
  the other way, from the earlier step, with `dir="back"`, so its arrowhead
  is on the earlier step. Then `dot` ranks the undo edge in the same
  direction as the edge that it undoes, and an undo edge cannot turn a
  forward edge upward. So the steps keep the forward order of the workflow,
  and an undo edge runs next to the edge that it undoes. The arrowhead is at
  the tail of the edge, so the `:undo` class sets `arrowtail`, not
  `arrowhead`.

  ## IDs and escaping

  Each step is a node with the ID `step_<name>`, and the start circle has the
  ID `start`. So the start node cannot have the ID of a step.

  Every ID and every label is a double-quoted string, with `"` and `\\`
  escaped. So a step name or a condition cannot break the file, and a `\\` in
  a label cannot start a Graphviz escape sequence such as `\\N`.

  Graphviz reads an HTML entity in a label, such as `&amp;`, as the
  character that it names. So the file writes each `&` in a label as
  `&amp;`, and the chart shows the text as it is. An ID keeps its `&`.

  ## Options

  * `:svg` — run `dot` and return the SVG, not the DOT source. Defaults to
    `false`. The SVG has its own width and height, in points, so an `<img>`
    tag shows it at full size. See "Graphviz" for where `dot` comes from.
  * `:direction` — `:down` (the default) or `:right`. Down matches the other
    charts. Right gives a long, thin chart. Use it only for a short chain of
    steps.
  * `:theme` — `:light` (the default) or `:dark`. See "Dark theme".
  * `:classes` — your own colours and line styles. See "Your own styles".

  `:theme` and `:classes` can also go under `config :ash_workflow, :dot`, to
  apply to every chart. An option merges over the config. An option or a
  config key set to `nil` is the same as one that is not set. A config that
  is not a keyword list raises `ArgumentError`.

  ## Your own styles

  DOT has no classes. So each node and each edge gets the attributes of its
  class in the file, and a change to a class changes every node or edge of
  that kind. To change a class, pass `:classes`:

      AshWorkflow.Charts.render(MyApp.Candidate, :dot,
        classes: [manual: [fillcolor: "#FFE4E6"], undo: [style: "dashed"]]
      )

  Each class merges over its default, key by key. So the example changes the
  fill of manual steps and keeps their amber border. The classes are:

  * `:automatic`, `:manual` and `:wait_state`, for the step kinds.
  * `:done`, `:failed`, `:expired` and `:end`, for terminal steps.
  * `:on_success`, `:on_error`, `:timeout` and `:undo`, for edges.

  A key is a Graphviz attribute name for a node or an edge, such as
  `:fillcolor`, `:penwidth` or `:style`, or `:URL`, which is in capitals. A
  value is a string, which the file quotes, or a number or a boolean, which
  it does not. A key that is not such a name, a value of another type, or an
  unknown class raises `ArgumentError`. `dot` checks the value itself, such
  as whether a colour is valid. `default_classes/1` gives the defaults for
  each theme.

  A list of classes applies to both themes. A fill for the light theme can
  then sit under the light text of the dark theme. To give each theme its own
  colours, put the classes under `:light` and `:dark`:

      AshWorkflow.Charts.render(MyApp.Candidate, :dot,
        theme: :dark,
        classes: [
          light: [manual: [fillcolor: "#FFE4E6"]],
          dark: [manual: [fillcolor: "#881337"]]
        ]
      )

  Only the entry for the current theme applies, and a theme with no entry
  keeps its defaults. When a list gives a theme twice, both entries apply in
  order, so the later entry wins key by key. A list that mixes `:light` or
  `:dark` with class names raises `ArgumentError`.

  ## Dark theme

  `theme: :dark` selects a dark background and a second set of classes, with
  deep fills, light borders and light text. An SVG has one palette. A page
  that follows the reader's theme needs one chart for each theme.

  A list of classes applies on top of the dark classes too. For colours that
  apply only to the dark theme, put them under `:dark`. See "Your own
  styles".

  ## Graphviz

  `svg: true` runs the `dot` command of Graphviz. Install Graphviz with the
  package manager of your system, for example `apt-get install graphviz` or
  `brew install graphviz`. This library does not download it.

      config :ash_workflow, :dot, path: "/opt/graphviz/bin/dot"

  * `:path` — the `dot` to run. A name with no `/`, such as `"dot"`, is a
    command on the `PATH`. A path with a `/` is a file, relative to the
    current directory, and `~` is the home directory. The file must be
    executable. Without `:path`, the chart runs `dot` from the `PATH`. `nil`
    and `""` are the same as no `:path`, so
    `path: System.get_env("DOT_PATH")` runs `dot` from the `PATH` when the
    variable is not set or is empty. Any other value that is not a string
    raises `ArgumentError`.

  When there is no `dot`, `svg: true` raises `ArgumentError`.
  `executable/0` gives the `dot` that `svg: true` runs. When `dot` draws the
  chart but prints a message, such as a warning about a colour that it does
  not know, the chart logs the message with `Logger.warning/1`.

  ## Contrast

  By the WCAG 2 formula, against the background of each theme:

  | Pair | Light theme | Dark theme |
  |---|---|---|
  | Step label text on its fill | above 16:1 | above 8.6:1 |
  | Edge label text on the background | above 18.9:1 | above 15.6:1 |
  | Any stroke on the background | above 3.6:1 | above 6.4:1 |
  """

  @behaviour AshWorkflow.Charts.Backend

  alias AshWorkflow.Charts.Command
  alias AshWorkflow.Charts.Format
  alias AshWorkflow.Charts.Graph
  alias AshWorkflow.Charts.Options
  alias AshWorkflow.Charts.Palette

  require Logger

  # One class per step kind, per terminal outcome and per edge kind. The
  # colours come from `AshWorkflow.Charts.Palette`, and these are the DOT
  # attributes that follow them in each class. `default_classes/1` gives
  # both, and `:classes` merges over them.
  #
  # A terminal step has square corners and two borders.
  # An undo edge is dotted and has a hollow arrowhead, so its shape tells it
  # apart from the other edges without colour. Its arrowhead is the
  # `arrowtail`, because the file writes it from the earlier step.
  @styles [
    automatic: [style: "rounded,filled"],
    manual: [style: "rounded,filled"],
    wait_state: [style: "rounded,filled,dashed"],
    done: [style: "filled", peripheries: 2],
    failed: [style: "filled", peripheries: 2],
    expired: [style: "filled", peripheries: 2],
    end: [style: "filled", peripheries: 2],
    on_success: [penwidth: 3],
    on_error: [],
    timeout: [style: "dashed"],
    undo: [style: "dotted", arrowtail: "onormal"]
  ]

  # The attributes that the Graphviz attribute reference lists for nodes or
  # for edges, https://graphviz.org/doc/info/attrs.html. Graphviz ignores a
  # name it does not know, so a misspelt key would change nothing.
  @attribute_keys ~w(area arrowhead arrowsize arrowtail class color colorscheme comment
                     constraint decorate dir distortion edgehref edgetarget edgetooltip edgeURL
                     fillcolor fixedsize fontcolor fontname fontsize gradientangle group head_lp
                     headclip headhref headlabel headport headtarget headtooltip headURL height
                     href id image imagepos imagescale label labelangle labeldistance labelfloat
                     labelfontcolor labelfontname labelfontsize labelhref labelloc labeltarget
                     labeltooltip labelURL layer len lhead lp ltail margin minlen nojustify
                     ordering orientation penwidth peripheries pin pos radius rects regular root
                     samehead sametail samplepoints shape shapefile showboxes sides skew sortv
                     style tail_lp tailclip tailhref taillabel tailport tailtarget tailtooltip
                     tailURL target tooltip URL vertices weight width xlabel xlp z)

  @rankdirs %{down: "TB", right: "LR"}

  @font "Helvetica"

  @doc """
  The attributes of each class when nothing overrides them, for a theme: a
  keyword list from the class name to the DOT attributes it sets. See the
  `:classes` and `:theme` options.

  A step class sets `fillcolor`, `color` and `fontcolor`, and an edge class
  sets `color`, before the line styles. The `:undo` class sets `arrowtail`,
  because the file writes an undo edge from the earlier step. See "Layout"
  in the module documentation.
  """
  @spec default_classes(:light | :dark) :: keyword(keyword())
  def default_classes(theme \\ :light) do
    for {class, colours} <- Palette.colours(theme) do
      {class, colour_attributes(colours, theme) ++ @styles[class]}
    end
  end

  # The palette names the label colour of a step only in the dark theme. DOT
  # has no theme to give a default, so a light step takes the text colour of
  # the light theme, the same near-black as an edge label: above 16:1 on
  # every light fill, by the WCAG 2 formula.
  defp colour_attributes(colours, theme) do
    case Keyword.fetch(colours, :fill) do
      {:ok, fill} ->
        [
          fillcolor: fill,
          color: colours[:stroke],
          fontcolor: Keyword.get(colours, :text, Palette.edge_label_colour(theme))
        ]

      :error ->
        [color: colours[:stroke]]
    end
  end

  @impl true
  def file_extension, do: "dot"

  @impl true
  def render(%Graph{} = graph, opts) do
    opts = Keyword.validate!(opts, svg: false, direction: :down, theme: nil, classes: [])

    theme = theme(opts)

    classes =
      Options.classes!(default_classes(theme), theme, opts[:classes], config(), options_spec())

    source = source(graph, Options.direction!(opts[:direction]), theme, classes)

    if opts[:svg], do: render_svg!(source), else: source
  end

  @doc """
  The theme a chart draws with: the `:theme` option, else the `:theme` under
  `config :ash_workflow, :dot`, else `:light`.

  Raises `ArgumentError` for a theme that is not `:light` or `:dark`.
  """
  @spec theme(keyword()) :: :light | :dark
  def theme(opts \\ []), do: Options.theme!(opts[:theme], config())

  # A key is a Graphviz attribute name, written into the file as it is, so it
  # must be one. See `AshWorkflow.Charts.Options` for the rest of the
  # checks and the merge.
  defp options_spec do
    %{
      backend: "DOT",
      config: :dot,
      known_keys: @attribute_keys,
      key: "DOT attribute name",
      keys: "DOT attributes",
      entry: "an attribute name",
      example: ~S([manual: [fillcolor: "#FFE4E6"]])
    }
  end

  @doc """
  The `dot` command that `svg: true` runs, or `nil` when there is none.

  This is the configured `:path`, when it names an executable file or a
  command on the `PATH`. Without `:path`, it is `dot` on the `PATH`. See
  "Graphviz" in the module documentation.

  Raises `ArgumentError` when `:path` is not a string, or when
  `config :ash_workflow, :dot` is not a keyword list.
  """
  @spec executable() :: Path.t() | nil
  def executable, do: Command.find(path() || "dot")

  # `nil` and `""` are the same as no `:path`, so a runtime config can read
  # the path from a variable that may not be set, or that is empty.
  defp path do
    case Keyword.get(config(), :path) do
      path when path in [nil, ""] ->
        nil

      path when is_binary(path) ->
        path

      other ->
        raise ArgumentError,
              "config :ash_workflow, :dot, path: must be a string, got: #{inspect(other)}"
    end
  end

  defp executable! do
    executable() ||
      case path() do
        nil ->
          raise ArgumentError,
                "svg: true runs the dot command of Graphviz, and dot is not on the PATH. " <>
                  "Install Graphviz, or set :path under config :ash_workflow, :dot."

        path ->
          raise ArgumentError,
                "config :ash_workflow, :dot sets :path to #{inspect(path)}, which is neither " <>
                  "an executable file nor a command on the PATH. Install Graphviz, or correct :path."
      end
  end

  # `dot` runs with the caller's environment. Graphviz reads no variable that
  # overrides an attribute in the file, and `GVBINDIR` may be what finds its
  # plugins. `dot` can draw the chart and still print a warning, such as for
  # a colour that it does not know, so the warning goes to the log.
  defp render_svg!(source) do
    case Command.render_svg(executable!(), "dot", source, &["-Tsvg", "-o", &2, &1]) do
      {:ok, svg, ""} ->
        svg

      {:ok, svg, messages} ->
        Logger.warning("dot printed a message while it drew the chart: #{messages}")
        svg

      {:error, message} ->
        raise ArgumentError, "dot rejected the diagram: #{message}"
    end
  end

  # `nil` is the same as no config. Any other value that is not a keyword
  # list raises here, with the name of the config.
  defp config do
    case Application.get_env(:ash_workflow, :dot) do
      nil ->
        []

      config ->
        if not Keyword.keyword?(config) do
          raise ArgumentError,
                "config :ash_workflow, :dot must be a keyword list, such as " <>
                  ~S([theme: :dark, path: "/usr/bin/dot"], got: ) <> inspect(config)
        end

        config
    end
  end

  defp source(graph, direction, theme, classes) do
    text = Palette.edge_label_colour(theme)

    [
      "digraph ",
      quote_string(inspect(graph.resource)),
      " {\n",
      "  graph [rankdir=#{@rankdirs[direction]}, bgcolor=",
      quote_string(Palette.background(theme)),
      ", fontname=",
      quote_string(@font),
      ", pad=0.3, nodesep=0.5, ranksep=0.6];\n",
      "  node [shape=box, fontname=",
      quote_string(@font),
      ", fontsize=14, margin=\"0.2,0.1\", penwidth=2];\n",
      "  edge [fontname=",
      quote_string(@font),
      ", fontsize=12, fontcolor=",
      quote_string(text),
      ", color=",
      quote_string(text),
      ", penwidth=1.5];\n",
      "  \"start\" [shape=circle, label=\"\", width=0.2, style=filled, fillcolor=",
      quote_string(text),
      ", color=",
      quote_string(text),
      "];\n",
      Enum.map(graph.nodes, &node_line(&1, graph, classes)),
      Enum.map(graph.nodes, &start_line/1),
      Enum.map(graph.edges, &edge_line(&1, classes)),
      "}\n"
    ]
  end

  defp node_line(node, graph, classes) do
    [
      "  ",
      step_id(node.id),
      " [label=",
      label(Format.node_text(node)),
      attributes(classes[node_class(node, graph)]),
      "];\n"
    ]
  end

  defp node_class(%{kind: :terminal} = node, graph), do: Palette.terminal_class(node.id, graph)
  defp node_class(node, _graph), do: node.kind

  defp start_line(%{initial?: true} = node), do: ["  \"start\" -> ", step_id(node.id), ";\n"]
  defp start_line(_node), do: []

  defp edge_line(edge, classes) do
    {from, to, dir} = ends(edge)

    [
      "  ",
      step_id(from),
      " -> ",
      step_id(to),
      " [label=",
      label(Format.edge_text(edge)),
      attributes(dir ++ Keyword.get(classes, edge.kind, [])),
      "];\n"
    ]
  end

  # An undo edge goes from a later step back to an earlier step. Written
  # from the earlier step, with `dir="back"`, it ranks as the edge that it
  # undoes. See "Layout" in the moduledoc.
  defp ends(%{kind: :undo} = edge), do: {edge.to, edge.from, [dir: "back"]}
  defp ends(edge), do: {edge.from, edge.to, []}

  defp attributes(attributes), do: Enum.map(attributes, &[", " | attribute(&1)])

  defp attribute({key, value}) when is_binary(value),
    do: [Atom.to_string(key), "=", quote_string(value)]

  # A float in fixed notation, because DOT reads no exponent such as `1.0e-5`.
  defp attribute({key, value}) when is_float(value),
    do: [Atom.to_string(key), "=", Options.decimal(value)]

  defp attribute({key, value}), do: "#{key}=#{value}"

  defp step_id(step_name), do: quote_string("step_#{step_name}")

  # Graphviz reads an HTML entity in a label, such as `&amp;`, as the
  # character that it names, so a label writes `&` as `&amp;`. An ID is not
  # a label, and keeps its `&`.
  defp label(text), do: text |> String.replace("&", "&amp;") |> quote_string()

  # DOT reads `\"` as a quote inside a quoted string. In a label, Graphviz
  # reads `\n` as a line break and `\\` as one backslash, so a `\` in the text
  # cannot start an escape sequence such as `\N`.
  defp quote_string(text) do
    escaped =
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    ["\"", escaped, "\""]
  end
end
