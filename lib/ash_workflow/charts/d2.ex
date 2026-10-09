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

  Each edge kind other than a transition has a symbol in its label as well
  as a colour. `on_success`, timeouts and undo also have a line style, and
  `on_error` is a plain red line with `✖`. So a reader who cannot tell the
  colours apart loses nothing. The label text comes from
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
  other is bad. `AshWorkflow.Charts.Palette.terminal_class/2` gives the class of
  one step.

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

  D2 ignores case in a key. So steps named `:approved` and `:Approved` would
  be one shape, and the edge between them a loop. For two such step names,
  `render/2` raises `ArgumentError`. Give the steps names that differ by more
  than case.

  D2's case rules for letters outside ASCII are not the rules of
  `String.downcase/1`. For example, D2 makes `σ` and `ς` one key. So in a key,
  each character outside ASCII, and each `~`, is its code point in lowercase
  hex between two `~`: the key of `:σ` is `"step_~3c3~"`. The label still
  shows the step's name.

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
  apply to every chart. An option merges over the config. An option or a
  config key set to `nil` is the same as one that is not set. A config that
  is not a keyword list raises `ArgumentError`.

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
  is a string, which the file quotes, or a number or a boolean. A float with
  no fraction, such as `2.0`, goes into the file as `2`. Most D2 keys, such as
  `"stroke-width"`, take only a whole number. `:opacity` takes a fraction,
  such as `0.5`. A key that is not a D2 `style` keyword, a value of another
  type, or an unknown class raises `ArgumentError`. `d2` checks the value
  itself, such as whether a colour is valid. `default_classes/1` gives the
  defaults for each theme.

  A list of classes applies to both themes. A fill for the light theme can
  then sit under the light text of the dark theme. To give each theme its own
  colours, put the classes under `:light` and `:dark`:

      AshWorkflow.Charts.render(MyApp.Candidate, :d2,
        theme: :dark,
        classes: [
          light: [manual: [fill: "#FFE4E6"]],
          dark: [manual: [fill: "#881337"]]
        ]
      )

  Only the entry for the current theme applies, and a theme with no entry
  keeps its defaults. When a list gives a theme twice, both entries apply in
  order, so the later entry wins key by key. A list that mixes `:light` or
  `:dark` with class names raises `ArgumentError`.

  ## Dark theme

  `theme: :dark` selects D2's dark theme, which sets the background and the
  default text colours. It also selects a second set of classes, with deep
  fills, light strokes and light text. An SVG has one palette. A page that
  follows the reader's theme needs one chart for each theme.

  A list of classes applies on top of the dark classes too. For colours that
  apply only to the dark theme, put them under `:dark`. See "Your own
  colours".

  ## Contrast

  By the WCAG 2 formula, against the background that each D2 theme draws:

  | Pair | Light theme | Dark theme |
  |---|---|---|
  | Step label text on its fill | above 16:1 | above 8.6:1 |
  | Edge label text on the background | 5.2:1 | 9.3:1 |
  | Any stroke on the background | above 3.6:1 | above 6.4:1 |
  """

  @behaviour AshWorkflow.Charts.Backend

  alias AshWorkflow.Charts.D2.Binary
  alias AshWorkflow.Charts.Format
  alias AshWorkflow.Charts.Graph
  alias AshWorkflow.Charts.Options
  alias AshWorkflow.Charts.Palette

  # One class per step kind, per terminal outcome and per edge kind. A shape
  # names its class, so the colours live in the block and nowhere else in the
  # file. The colours come from `AshWorkflow.Charts.Palette`, and these are
  # the D2 `style` keys that follow them in each class. `default_classes/1`
  # gives both, and `:classes` merges over them.
  @styles [
    automatic: ["border-radius": 4],
    manual: ["border-radius": 4],
    wait_state: ["stroke-dash": 3, "border-radius": 4],
    done: ["double-border": true],
    failed: ["double-border": true],
    expired: ["double-border": true],
    end: ["double-border": true],
    on_success: ["stroke-width": 3],
    on_error: [],
    timeout: ["stroke-dash": 5],
    undo: ["stroke-dash": 2]
  ]

  # The `style` keywords of d2 v0.9.0. d2 rejects any other key.
  @style_keys ~w(3d animated bold border-radius double-border fill fill-pattern filled font
                 font-color font-size italic multiple opacity shadow stroke stroke-dash
                 stroke-width text-transform underline)

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
  def default_classes(theme \\ :light) do
    for {class, colours} <- Palette.colours(theme) do
      {class, Enum.map(colours, &colour_style/1) ++ @styles[class]}
    end
  end

  # A palette colour as a D2 `style` key: D2 calls the text colour `font-color`.
  defp colour_style({:text, colour}), do: {:"font-color", colour}
  defp colour_style(colour), do: colour

  @impl true
  def file_extension, do: "d2"

  @impl true
  def render(%Graph{} = graph, opts) do
    opts =
      Keyword.validate!(opts, svg: false, direction: :down, layout: :elk, theme: nil, classes: [])

    theme = theme(opts)

    classes =
      Options.classes!(default_classes(theme), theme, opts[:classes], config(), options_spec())

    source =
      source(graph, Options.direction!(opts[:direction]), layout!(opts[:layout]), theme, classes)

    if opts[:svg], do: Binary.render_svg!(source, @svg_args), else: source
  end

  @doc """
  The theme a chart draws with: the `:theme` option, else the `:theme` under
  `config :ash_workflow, :d2`, else `:light`.

  Raises `ArgumentError` for a theme that is not `:light` or `:dark`.
  """
  @spec theme(keyword()) :: :light | :dark
  def theme(opts \\ []), do: Options.theme!(opts[:theme], config())

  # A style key is a D2 `style` keyword, written into the file as it is, so it
  # must be one. See `AshWorkflow.Charts.Options` for the rest of the checks
  # and the merge.
  defp options_spec do
    %{
      backend: "D2",
      config: :d2,
      known_keys: @style_keys,
      key: "D2 style key",
      keys: "style keys",
      entry: "a style key",
      example: ~S([manual: [fill: "#FFE4E6"]])
    }
  end

  defp config, do: Binary.config()

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

  defp style_pair({key, value}) when is_float(value), do: "#{key}: #{float_text(value)}"
  defp style_pair({key, value}), do: "#{key}: #{value}"

  # d2 takes a whole number only as an integer: it rejects `stroke-width: 2.0`.
  # Any other float is in fixed notation, with no exponent.
  defp float_text(value) when value == trunc(value), do: Integer.to_string(trunc(value))
  defp float_text(value), do: Options.decimal(value)

  defp layout!(nil), do: :elk
  defp layout!(layout) when layout in [:elk, :dagre], do: layout

  defp layout!(other),
    do: raise(ArgumentError, "layout must be :elk or :dagre, got: #{inspect(other)}")

  defp source(graph, direction, layout, theme, classes) do
    check_keys!(graph)

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
      quote_string(Format.node_text(node)),
      " {class: ",
      node_class(node, graph),
      "}\n"
    ]
  end

  defp node_class(%{kind: :terminal} = node, graph),
    do: node.id |> Palette.terminal_class(graph) |> Atom.to_string()

  defp node_class(node, _graph), do: Atom.to_string(node.kind)

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

  defp step_key(step_name), do: key("step_", step_name)

  # D2 ignores case in a key. So `:Approved` and `:approved` would be one
  # shape, and the edge between them a loop. A key is all ASCII, see
  # `key_text/1`, and for ASCII D2's rule is `String.downcase/1`.
  defp check_keys!(graph) do
    graph.nodes
    |> Enum.group_by(&String.downcase(key_text(&1.id)), & &1.id)
    |> Enum.filter(fn {_key, names} -> length(names) > 1 end)
    |> case do
      [] ->
        :ok

      clashes ->
        raise ArgumentError,
              "these step names map to the same D2 key, because D2 keys ignore case: " <>
                Enum.map_join(clashes, "; ", fn {key, names} ->
                  "#{inspect(names)} -> step_#{key}"
                end)
    end
  end

  # A key of only A-Z, a-z, 0-9 and _ stays bare. Any other key is quoted, so
  # a `.` cannot nest one shape in another and a `-` cannot read as part of a
  # connection. A quoted key and a bare key with the same text name the same
  # shape, and no two step names give the same text. Keys that differ only in
  # case also name one shape, and `check_keys!/1` raises for them.
  defp key(prefix, name) do
    key = prefix <> key_text(name)
    if key =~ ~r/\A[A-Za-z0-9_]+\z/, do: key, else: quote_string(key)
  end

  # D2's case folding outside ASCII differs from `String.downcase/1`: it makes
  # `σ` and `ς` one key, and keeps `İ` and `i̇` apart. So each character
  # outside ASCII becomes `~<code point in lowercase hex>~`, and the key is
  # all ASCII. `~` itself is written the same way, so no two names give the
  # same key.
  defp key_text(name) do
    name
    |> to_string()
    |> String.to_charlist()
    |> Enum.map(fn
      char when char < 128 and char != ?~ -> <<char>>
      char -> "~#{char |> Integer.to_string(16) |> String.downcase()}~"
    end)
    |> IO.iodata_to_binary()
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
