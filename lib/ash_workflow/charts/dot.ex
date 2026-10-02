defmodule AshWorkflow.Charts.Dot do
  @moduledoc """
  Draws an `AshWorkflow.Charts.Graph` as a [Graphviz](https://graphviz.org)
  DOT diagram.

  DOT is the text format of Graphviz. Its `dot` command lays a diagram out
  and draws it as SVG, PNG or PDF, and many other tools read DOT. This chart
  has the same colours, line styles and labels as `AshWorkflow.Charts.D2`.
  Use it when Graphviz is already on your machines.

      # The DOT source, to keep in the repository or to draw yourself:
      AshWorkflow.Charts.render(MyApp.Candidate, :dot)

      # The SVG. This runs `dot`, which must be installed:
      AshWorkflow.Charts.render(MyApp.Candidate, :dot, svg: true)

  ## What the chart shows

  The chart shows the same things as the D2 chart, in the same colours. See
  "What the chart shows" in `AshWorkflow.Charts.D2`. The colours come from
  `AshWorkflow.Charts.Palette`.

  | In the workflow | In the chart |
  |---|---|
  | Step | A box with the step's name, and its kind under the name |
  | Wait state | A dashed border |
  | Terminal step | A double border, coloured by the edges that reach it |
  | Initial step | An edge from a small filled circle |
  | `on_success` | A thick edge |
  | Timeout | A dashed edge |
  | Undo | A dotted edge with an open arrowhead |
  | Step notes | Under a rule inside the step |

  `AshWorkflow.Charts.Palette.terminal_class/2` gives the colour class of a
  terminal step. The label text comes from `AshWorkflow.Charts.Format`, so it
  is the same in every format.

  ## Layout

  `dot` puts the steps in ranks, from the initial step to the end steps. An
  edge that closes a loop, such as an undo edge, goes back up the ranks. So
  the steps keep the forward order of the workflow, and an undo edge runs
  next to the edge that it undoes.

  ## IDs and escaping

  Each step is a node with the ID `step_<name>`, and the start circle has the
  ID `start`. So the start node cannot have the ID of a step.

  Every ID and every label is a double-quoted string, with `"` and `\\`
  escaped. So a step name or a condition cannot break the file, and a `\\` in
  a label cannot start a Graphviz escape sequence such as `\\N`.

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
  apply to every chart. An option merges over the config.

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

  A key is a Graphviz attribute name, such as `:fillcolor`, `:penwidth` or
  `:style`. A value is a string, which the file quotes, or a number or a
  boolean, which it does not. Any other key or value, or an unknown class,
  raises `ArgumentError`. `default_classes/1` gives the defaults for each
  theme.

  ## Dark theme

  `theme: :dark` selects a dark background and a second set of classes, with
  deep fills, light borders and light text. An SVG has one palette. A page
  that follows the reader's theme needs one chart for each theme.

  ## Graphviz

  `svg: true` runs the `dot` command of Graphviz. Install Graphviz with the
  package manager of your system, for example `apt-get install graphviz` or
  `brew install graphviz`. This library does not download it.

      config :ash_workflow, :dot, path: "/opt/graphviz/bin/dot"

  * `:path` — the `dot` to run: a file path, or a command name that is on
    the `PATH`. Without `:path`, the chart runs `dot` from the `PATH`.

  When there is no `dot`, `svg: true` raises `ArgumentError`.
  `executable/0` gives the `dot` that `svg: true` runs.

  ## Contrast

  By the WCAG 2 formula, against the background of each theme:

  | Pair | Light theme | Dark theme |
  |---|---|---|
  | Step label text on its fill | above 16:1 | above 8.6:1 |
  | Edge label text on the background | above 18.9:1 | above 15.6:1 |
  | Any stroke on the background | above 3.6:1 | above 6.4:1 |
  """

  @behaviour AshWorkflow.Charts.Backend

  alias AshWorkflow.Charts.Format
  alias AshWorkflow.Charts.Graph
  alias AshWorkflow.Charts.Palette

  # One class per step kind, per terminal outcome and per edge kind. The
  # colours come from `AshWorkflow.Charts.Palette`, and these are the DOT
  # attributes that follow them in each class. `default_classes/1` gives
  # both, and `:classes` merges over them.
  #
  # A terminal step has square corners and two borders, as in the D2 chart.
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
    undo: [style: "dotted", arrowhead: "vee"]
  ]

  @rankdirs %{down: "TB", right: "LR"}

  @font "Helvetica"

  @doc """
  The attributes of each class when nothing overrides them, for a theme: a
  keyword list from the class name to the DOT attributes it sets. See the
  `:classes` and `:theme` options.

  A step class sets `fillcolor`, `color` and `fontcolor`, and an edge class
  sets `color`, before the line styles.
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

    theme = theme!(opts[:theme] || Keyword.get(config(), :theme, :light))
    classes = classes!(theme, opts[:classes])
    source = source(graph, direction!(opts[:direction]), theme, classes)

    if opts[:svg], do: render_svg!(source), else: source
  end

  @doc """
  The `dot` command that `svg: true` runs, or `nil` when there is none.

  This is the configured `:path`, when it names a file or a command on the
  `PATH`. Without `:path`, it is `dot` on the `PATH`.
  """
  @spec executable() :: Path.t() | nil
  def executable do
    case Keyword.fetch(config(), :path) do
      {:ok, path} -> if File.regular?(path), do: path, else: System.find_executable(path)
      :error -> System.find_executable("dot")
    end
  end

  defp executable! do
    executable() ||
      case Keyword.fetch(config(), :path) do
        {:ok, path} ->
          raise ArgumentError,
                "config :ash_workflow, :dot sets :path to #{inspect(path)}, which is neither " <>
                  "a file nor a command on the PATH. Install Graphviz, or correct :path."

        :error ->
          raise ArgumentError,
                "svg: true runs the dot command of Graphviz, and dot is not on the PATH. " <>
                  "Install Graphviz, or set :path under config :ash_workflow, :dot."
      end
  end

  # `dot` writes its messages to stderr, and a port cannot keep stderr apart
  # from stdout, so the SVG goes to a file and the messages come back as the
  # command output.
  defp render_svg!(source) do
    dot = executable!()

    base =
      Path.join(
        System.tmp_dir!(),
        "ash_workflow_dot_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    input = base <> ".dot"
    output = base <> ".svg"
    File.write!(input, source)

    try do
      case System.cmd(dot, ["-Tsvg", "-o", output, input], stderr_to_stdout: true) do
        {_messages, 0} ->
          File.read!(output)

        {messages, _status} ->
          message = messages |> String.replace(input, "diagram") |> String.trim()
          raise ArgumentError, "dot rejected the diagram: #{message}"
      end
    after
      File.rm(input)
      File.rm(output)
    end
  end

  # The configured classes merge over the defaults, and the option merges over
  # both. A class keeps the default keys it does not set, so `color: "#000"`
  # on `manual` keeps the amber fill.
  defp classes!(theme, option) do
    configured =
      config()
      |> Keyword.get(:classes, [])
      |> validate_classes!("config :ash_workflow, :dot, classes:")

    option = validate_classes!(option, "the :classes option")

    Enum.reduce(configured ++ option, default_classes(theme), &merge_class/2)
  end

  # The shape is a keyword list of keyword lists, and a key is a Graphviz
  # attribute name, written into the file as it is. So a key must look like
  # one, and a value must be a string, which is quoted, or a number or a
  # boolean, which is not. Anything else would break the file.
  defp validate_classes!(classes, source) do
    if not (is_list(classes) and
              Enum.all?(
                classes,
                &match?({class, attributes} when is_atom(class) and is_list(attributes), &1)
              )) do
      raise ArgumentError,
            "#{source} must be a keyword list from a class name to a keyword list of DOT " <>
              "attributes, such as [manual: [fillcolor: \"#FFE4E6\"]], got: #{inspect(classes)}"
    end

    Enum.map(classes, fn {class, attributes} ->
      {class, Enum.map(attributes, &attribute!(&1, class, source))}
    end)
  end

  defp attribute!({key, value}, class, source) when is_atom(key) or is_binary(key) do
    key = to_string(key)

    cond do
      not String.match?(key, ~r/\A[a-z][a-z0-9_]*\z/) ->
        raise ArgumentError,
              "#{source}: #{inspect(key)} under #{inspect(class)} is not a DOT attribute name"

      not (is_binary(value) or is_number(value) or is_boolean(value)) ->
        raise ArgumentError,
              "#{source}: #{key} under #{inspect(class)} must be a string, a number or a boolean, " <>
                "got: #{inspect(value)}"

      true ->
        {String.to_atom(key), value}
    end
  end

  defp attribute!(other, class, source) do
    raise ArgumentError,
          "#{source}: #{inspect(other)} under #{inspect(class)} is not an attribute name and value"
  end

  defp config, do: Application.get_env(:ash_workflow, :dot, [])

  defp theme!(theme) when theme in [:light, :dark], do: theme

  defp theme!(other),
    do: raise(ArgumentError, "theme must be :light or :dark, got: #{inspect(other)}")

  defp merge_class({class, attributes}, classes) do
    if not Keyword.has_key?(classes, class) do
      raise ArgumentError,
            "unknown DOT class #{inspect(class)}. The classes are #{inspect(Keyword.keys(@styles))}"
    end

    Keyword.update!(classes, class, &merge_attributes(&1, attributes))
  end

  # Keeps the default key order, so an override changes a value in place and
  # a new key goes last. `Keyword.merge/2` would move a changed key to the end.
  defp merge_attributes(default, overrides) do
    kept = Enum.map(default, fn {key, value} -> {key, Keyword.get(overrides, key, value)} end)
    kept ++ Enum.reject(overrides, fn {key, _value} -> Keyword.has_key?(default, key) end)
  end

  defp direction!(direction) when is_map_key(@rankdirs, direction), do: direction

  defp direction!(other),
    do: raise(ArgumentError, "direction must be :down or :right, got: #{inspect(other)}")

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
      quote_string(Format.node_text(node)),
      attributes(classes[node_class(node, graph)]),
      "];\n"
    ]
  end

  defp node_class(%{kind: :terminal} = node, graph), do: Palette.terminal_class(node.id, graph)
  defp node_class(node, _graph), do: node.kind

  defp start_line(%{initial?: true} = node), do: ["  \"start\" -> ", step_id(node.id), ";\n"]
  defp start_line(_node), do: []

  defp edge_line(edge, classes) do
    [
      "  ",
      step_id(edge.from),
      " -> ",
      step_id(edge.to),
      " [label=",
      quote_string(Format.edge_text(edge)),
      attributes(Keyword.get(classes, edge.kind, [])),
      "];\n"
    ]
  end

  defp attributes(attributes), do: Enum.map(attributes, &[", " | attribute(&1)])

  defp attribute({key, value}) when is_binary(value),
    do: [Atom.to_string(key), "=", quote_string(value)]

  # A float in fixed notation, because DOT reads no exponent such as `1.0e-5`.
  defp attribute({key, value}) when is_float(value),
    do: [Atom.to_string(key), "=", :erlang.float_to_binary(value, [:compact, decimals: 10])]

  defp attribute({key, value}), do: "#{key}=#{value}"

  defp step_id(step_name), do: quote_string("step_#{step_name}")

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
