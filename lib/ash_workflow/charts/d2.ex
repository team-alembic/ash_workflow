defmodule AshWorkflow.Charts.D2 do
  @moduledoc """
  Draws an `AshWorkflow.Charts.Graph` as a [D2](https://d2lang.com) diagram.

  D2 is a text format for diagrams, with its own `d2` command that lays a
  diagram out and draws it as SVG. Use this backend when you want a chart
  with colour and line styles, for a README, a design document or an
  operations page. For a chart that GitHub, Livebook and ExDoc draw with no
  other tool, use `AshWorkflow.Charts.Mermaid`.

      # The D2 source, to keep in the repository or to draw yourself:
      AshWorkflow.Charts.render(MyApp.Candidate, :d2)

      # The SVG. The first call downloads `d2`:
      AshWorkflow.Charts.render(MyApp.Candidate, :d2, svg: true)

  `svg: true` runs `d2` through `AshWorkflow.Charts.D2.Binary`. That module
  downloads the `d2` release this library pins, the first time you need it.

  ## What the chart shows

  | In the workflow | In the chart |
  |---|---|
  | Automatic step | Blue box, `⚙\u{FE0F} automatic` under the name |
  | Manual step | Amber box, `✋ manual` under the name |
  | Wait state | Lavender box with a dashed border, `⏳ wait state` under the name |
  | Terminal step | Double border. Green, red, amber or grey: see "Terminal steps" |
  | Initial step | An edge from a small circle |
  | `on_success` | Thick blue edge, `⚙` and the action |
  | `on_error` | Red edge, `✖ on_error` |
  | Timeout | Dashed amber edge, `⏱`, the timeout's name and its deadline |
  | Undo | Dotted grey edge, `↶ undo`, and the window when `within` is set |
  | Transition | Plain edge, the transition's name |
  | Step notes | Under a rule inside the step: `policy:`, `retry:`, `⏱` and `↻` |

  Each edge kind has a line style and a symbol as well as a colour. A reader
  who cannot tell the colours apart loses nothing. The label text comes from
  `AshWorkflow.Charts.Format.edge_text/1`, so it is the same in every format.

  ## Terminal steps

  The colour of a terminal step comes from the edges that reach it:

  * **Red** when only `on_error` edges reach it.
  * **Amber** when only timeouts reach it.
  * **Green** when only transitions and `on_success` reach it.
  * **Grey** for a mix of these, or for no edge at all.

  This rule reads the edges, not the step's name. A step named `rejected`
  that a person chooses is green, because the workflow reaches it the same
  way as `approved`. The backend cannot know that one outcome is good and the
  other is bad. `terminal_class/2` gives the class of one step.

  ## Layout

  The file selects D2's ELK layout engine, in a `d2-config` block at its
  top. So `d2 file.d2` uses ELK with no flag. ELK draws straight edges, and
  it routes the undo edges and the long edges to an end step in clear lanes.

  A step's notes sit inside the step, under a rule. A separate note shape is
  one more box for the layout engine to place, and it pulls the steps out of
  line.

  ## Keys and escaping

  Each step is a shape with the key `step_<name>`. The prefix keeps a step
  name such as `:label` or `:shape` away from D2's keywords. A key with any
  character outside `A-Z`, `a-z`, `0-9` and `_` is quoted. So a `.` in a step
  name cannot put one shape inside another.

  Every label is a double-quoted string, with `"`, `\\` and `$` escaped. So a
  condition cannot break the file, and a `$` cannot start a D2 substitution.

  ## Options

  * `:svg` — run `d2` and return the SVG, not the D2 source. Defaults to
    `false`. The SVG has its own width and height, so an `<img>` tag shows it
    at full size, and CSS such as `max-width: 100%` can still shrink it. See
    `AshWorkflow.Charts.D2.Binary` for where `d2` comes from.
  * `:direction` — `:down` (the default) or `:right`. Down matches the
    Mermaid chart. Right gives a long, thin chart, because each edge label
    adds to its length. Use it only for a short chain of steps.
  * `:layout` — `:elk` (the default) or `:dagre`. These are the two layout
    engines that `d2` includes. Dagre draws curved edges.
  * `:theme` — `:light` (the default) or `:dark`. See "Dark theme".
  * `:classes` — your own colours. See "Your own colours".

  `:theme` and `:classes` can also go under `config :ash_workflow, :d2`, to
  apply to every chart. An option merges over the config.

  ## Your own colours

  The colours are in a `classes` block at the top of the file. Each shape
  names its class, so one change in the block changes every shape of that
  kind. To change a class, pass `:classes`:

      AshWorkflow.Charts.render(MyApp.Candidate, :d2,
        classes: [manual: [fill: "#FFE4E6"], undo: ["stroke-dash": 4]]
      )

  Each class merges over its default, key by key. So the example changes the
  fill of manual steps and keeps their amber stroke. The classes are:

  * `:automatic`, `:manual` and `:wait_state`, for the step kinds.
  * `:done`, `:failed`, `:expired` and `:end`, for terminal steps.
  * `:on_success`, `:on_error`, `:timeout` and `:undo`, for edges.

  A key is a D2 `style` keyword, such as `:fill` or `"stroke-dash"`. A value
  is a string, which the file quotes, or a number or a boolean. Any other key
  or value, or an unknown class, raises `ArgumentError`. `default_classes/1`
  gives the defaults for each theme.

  ## Dark theme

  `theme: :dark` selects D2's dark theme, which sets the background and the
  default text colours. It also selects a second set of classes, with deep
  fills, light strokes and light text. An SVG has one palette. A page that
  follows the reader's theme needs one chart for each theme.

  ## Contrast

  By the WCAG 2 formula, against the background that each D2 theme draws:

  | Pair | Light theme | Dark theme |
  |---|---|---|
  | Step label text on its fill | above 16:1 | above 8.7:1 |
  | Edge label text on the background | 5.2:1 | 9.3:1 |
  | Any stroke on the background | above 3.6:1 | above 6.5:1 |
  """

  @behaviour AshWorkflow.Charts.Backend

  alias AshWorkflow.Charts.D2.Binary
  alias AshWorkflow.Charts.Format
  alias AshWorkflow.Charts.Graph

  # One class per step kind, per terminal outcome and per edge kind. A shape
  # names its class, so the colours live in the block and nowhere else in the
  # file. `default_classes/1` gives these, and `:classes` merges over them.
  @default_classes [
    automatic: [fill: "#E8F0FE", stroke: "#1A56DB", "border-radius": 4],
    manual: [fill: "#FFF4E5", stroke: "#B7791F", "border-radius": 4],
    wait_state: [fill: "#F3E8FF", stroke: "#6B46C1", "stroke-dash": 3, "border-radius": 4],
    done: [fill: "#E6F4EA", stroke: "#1E7B34", "double-border": true],
    failed: [fill: "#FDE8E8", stroke: "#C81E1E", "double-border": true],
    expired: [fill: "#FEF3C7", stroke: "#B45309", "double-border": true],
    end: [fill: "#F3F4F6", stroke: "#4B5563", "double-border": true],
    on_success: [stroke: "#1A56DB", "stroke-width": 3],
    on_error: [stroke: "#C81E1E"],
    timeout: [stroke: "#B45309", "stroke-dash": 5],
    undo: [stroke: "#6B7280", "stroke-dash": 2]
  ]

  # The same classes for a dark page: deep fills, light strokes and light text.
  # Text on every fill is above 8.7:1, and every stroke on D2's dark background
  # (#1E1E2E) is above 6.5:1, by the WCAG 2 formula.
  @dark_classes [
    automatic: [fill: "#1E3A8A", stroke: "#93C5FD", "font-color": "#F8FAFC", "border-radius": 4],
    manual: [fill: "#78350F", stroke: "#FCD34D", "font-color": "#F8FAFC", "border-radius": 4],
    wait_state: [
      fill: "#4C1D95",
      stroke: "#C4B5FD",
      "font-color": "#F8FAFC",
      "stroke-dash": 3,
      "border-radius": 4
    ],
    done: [fill: "#14532D", stroke: "#86EFAC", "font-color": "#F8FAFC", "double-border": true],
    failed: [fill: "#7F1D1D", stroke: "#FCA5A5", "font-color": "#F8FAFC", "double-border": true],
    expired: [fill: "#78350F", stroke: "#FCD34D", "font-color": "#F8FAFC", "double-border": true],
    end: [fill: "#1F2937", stroke: "#D1D5DB", "font-color": "#F8FAFC", "double-border": true],
    on_success: [stroke: "#93C5FD", "stroke-width": 3],
    on_error: [stroke: "#FCA5A5"],
    timeout: [stroke: "#FCD34D", "stroke-dash": 5],
    undo: [stroke: "#9CA3AF", "stroke-dash": 2]
  ]

  # D2's theme IDs: 0 is "Neutral default", 200 is "Dark Mauve".
  @theme_ids %{light: 0, dark: 200}

  # By default `d2` writes an SVG with a viewBox and no width or height, to fit
  # a browser window. In an `<img>` tag such an SVG has no size of its own, so
  # a browser draws it in a small default box. `--scale 1` writes the width
  # and the height, and the image shows at full size.
  @svg_args ["--scale", "1"]

  @doc """
  The style of each class when nothing overrides it, for a theme: a keyword
  list from the class name to the D2 `style` keys it sets. See the `:classes`
  and `:theme` options.
  """
  @spec default_classes(:light | :dark) :: keyword(keyword())
  def default_classes(theme \\ :light)
  def default_classes(:light), do: @default_classes
  def default_classes(:dark), do: @dark_classes

  @impl true
  def file_extension, do: "d2"

  @impl true
  def render(%Graph{} = graph, opts) do
    opts =
      Keyword.validate!(opts, svg: false, direction: :down, layout: :elk, theme: nil, classes: [])

    theme = theme!(opts[:theme] || Keyword.get(config(), :theme, :light))
    classes = classes!(theme, opts[:classes])

    source =
      source(graph, direction!(opts[:direction]), layout!(opts[:layout]), theme, classes)

    if opts[:svg], do: Binary.render_svg!(source, @svg_args), else: source
  end

  # The configured classes merge over the defaults, and the option merges over
  # both. A class keeps the default keys it does not set, so `stroke: "#000"`
  # on `manual` keeps the amber fill.
  defp classes!(theme, option) do
    configured =
      config()
      |> Keyword.get(:classes, [])
      |> validate_classes!("config :ash_workflow, :d2, classes:")

    option = validate_classes!(option, "the :classes option")

    Enum.reduce(configured ++ option, default_classes(theme), &merge_class/2)
  end

  # The shape is a keyword list of keyword lists, and a style key is a D2
  # `style` keyword, written into the file as it is. So a key must look like
  # one, and a value must be a string, which is quoted, or a number or a
  # boolean, which is not. Anything else would break the file.
  defp validate_classes!(classes, source) do
    if not (is_list(classes) and
              Enum.all?(
                classes,
                &match?({class, style} when is_atom(class) and is_list(style), &1)
              )) do
      raise ArgumentError,
            "#{source} must be a keyword list from a class name to a keyword list of style keys, " <>
              "such as [manual: [fill: \"#FFE4E6\"]], got: #{inspect(classes)}"
    end

    Enum.map(classes, fn {class, style} ->
      {class, Enum.map(style, &style_entry!(&1, class, source))}
    end)
  end

  defp style_entry!({key, value}, class, source) when is_atom(key) or is_binary(key) do
    key = to_string(key)

    cond do
      not String.match?(key, ~r/\A[a-z][a-z0-9-]*\z/) ->
        raise ArgumentError,
              "#{source}: #{inspect(key)} under #{inspect(class)} is not a D2 style key"

      not (is_binary(value) or is_number(value) or is_boolean(value)) ->
        raise ArgumentError,
              "#{source}: #{key} under #{inspect(class)} must be a string, a number or a boolean, " <>
                "got: #{inspect(value)}"

      true ->
        {String.to_atom(key), value}
    end
  end

  defp style_entry!(other, class, source) do
    raise ArgumentError,
          "#{source}: #{inspect(other)} under #{inspect(class)} is not a style key and value"
  end

  defp config, do: Application.get_env(:ash_workflow, :d2, [])

  defp theme!(theme) when is_map_key(@theme_ids, theme), do: theme

  defp theme!(other),
    do: raise(ArgumentError, "theme must be :light or :dark, got: #{inspect(other)}")

  defp merge_class({class, style}, classes) do
    if not Keyword.has_key?(classes, class) do
      raise ArgumentError,
            "unknown D2 class #{inspect(class)}. The classes are #{inspect(Keyword.keys(@default_classes))}"
    end

    Keyword.update!(classes, class, &merge_style(&1, style))
  end

  # Keeps the default key order, so an override changes a value in place and
  # a new key goes last. `Keyword.merge/2` would move a changed key to the end.
  defp merge_style(default, overrides) do
    kept = Enum.map(default, fn {key, value} -> {key, Keyword.get(overrides, key, value)} end)
    kept ++ Enum.reject(overrides, fn {key, _value} -> Keyword.has_key?(default, key) end)
  end

  defp classes_block(classes) do
    [
      "classes: {\n",
      Enum.map(classes, fn {class, style} ->
        [
          "  ",
          Atom.to_string(class),
          ": {style: {",
          Enum.map_join(style, "; ", &style_pair/1),
          "}}\n"
        ]
      end),
      "}\n"
    ]
  end

  defp style_pair({key, value}) when is_binary(value),
    do: [Atom.to_string(key), ": ", quote_string(value)]

  defp style_pair({key, value}), do: "#{key}: #{value}"

  defp direction!(direction) when direction in [:down, :right], do: direction

  defp direction!(other),
    do: raise(ArgumentError, "direction must be :down or :right, got: #{inspect(other)}")

  defp layout!(layout) when layout in [:elk, :dagre], do: layout

  defp layout!(other),
    do: raise(ArgumentError, "layout must be :elk or :dagre, got: #{inspect(other)}")

  defp source(graph, direction, layout, theme, classes) do
    [
      "vars: {\n  d2-config: {\n    layout-engine: #{layout}\n    theme-id: #{@theme_ids[theme]}\n  }\n}\n",
      "direction: #{direction}\n",
      classes_block(classes),
      "start: \"\" {shape: circle; width: 16; height: 16}\n",
      Enum.map(graph.nodes, &node_line(&1, graph)),
      Enum.map(graph.nodes, &start_line/1),
      Enum.map(graph.edges, &edge_line/1)
    ]
  end

  defp node_line(node, graph) do
    [
      step_key(node.id),
      ": ",
      quote_string(node_label(node)),
      " {class: ",
      node_class(node, graph),
      "}\n"
    ]
  end

  # A terminal step has no kind line, but it keeps its notes, as in the
  # other formats.
  defp node_label(%{kind: :terminal} = node),
    do: Enum.join([to_string(node.id) | notes_label(node.notes)], "\n—\n")

  defp node_label(node) do
    Enum.join(["#{node.id}\n#{Format.kind_text(node.kind)}" | notes_label(node.notes)], "\n—\n")
  end

  defp node_class(%{kind: :terminal} = node, graph), do: terminal_class(node.id, graph)
  defp node_class(node, _graph), do: Atom.to_string(node.kind)

  @doc """
  The class of a terminal step, from the kinds of the edges that reach it:
  `"failed"` for `on_error` only, `"expired"` for timeouts only, `"done"` for
  transitions and `on_success` only, and `"end"` for a mix or for no edge.

  Undo edges leave a step and do not count. The rule reads the edges, not the
  step's name, so a step a person chooses is `"done"` whatever it is called.
  """
  @spec terminal_class(atom(), Graph.t()) :: String.t()
  def terminal_class(step, %Graph{} = graph) do
    kinds =
      graph.edges
      |> Enum.filter(&(&1.to == step and &1.kind != :undo))
      |> Enum.map(& &1.kind)
      |> Enum.uniq()

    cond do
      kinds == [] -> "end"
      kinds == [:on_error] -> "failed"
      kinds == [:timeout] -> "expired"
      Enum.all?(kinds, &(&1 in [:transition, :on_success])) -> "done"
      true -> "end"
    end
  end

  defp start_line(%{initial?: true} = node), do: ["start -> ", step_key(node.id), "\n"]
  defp start_line(_node), do: []

  defp edge_line(edge) do
    [
      step_key(edge.from),
      " -> ",
      step_key(edge.to),
      ": ",
      quote_string(Format.edge_text(edge)),
      edge_class(edge.kind),
      "\n"
    ]
  end

  defp edge_class(:transition), do: ""
  defp edge_class(kind), do: " {class: #{kind}}"

  defp notes_label([]), do: []
  defp notes_label(notes), do: [Enum.map_join(notes, "\n", &Format.note_text/1)]

  defp step_key(step_name), do: key("step_", step_name)

  # A key of only A-Z, a-z, 0-9 and _ stays bare. Any other key is quoted, so
  # a `.` cannot nest one shape in another and a `-` cannot read as part of a
  # connection. A quoted key and a bare key name the same shape, but no step
  # name gives both, so two steps cannot share a key.
  defp key(prefix, name) do
    key = prefix <> to_string(name)
    if key =~ ~r/\A[A-Za-z0-9_]+\z/, do: key, else: quote_string(key)
  end

  defp quote_string(text) do
    escaped =
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("$", "\\$")
      |> String.replace("\n", "\\n")

    ["\"", escaped, "\""]
  end
end
