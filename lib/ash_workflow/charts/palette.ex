defmodule AshWorkflow.Charts.Palette do
  @moduledoc """
  The colours of the charts that `AshWorkflow.Charts.Dot` draws, for each
  theme. A backend that draws in colour reads them here, so every such chart
  has the same look.

  The palette has one class for each step kind, terminal outcome and edge
  kind.

  `:light` is for a light page. `:dark` is for a dark page, with deep fills,
  light strokes and light text.
  """

  alias AshWorkflow.Charts.Graph

  @type theme :: :light | :dark

  @type class ::
          :automatic
          | :manual
          | :wait_state
          | :done
          | :failed
          | :expired
          | :end
          | :on_success
          | :on_error
          | :timeout
          | :undo

  # The contrast of each pair by the WCAG 2 formula:
  #
  # | Pair                              | Light       | Dark        |
  # |-----------------------------------|-------------|-------------|
  # | Step label text on any fill       | above 16.0  | above 8.6   |
  # | Edge label text on the background | above 18.9  | above 15.6  |
  # | Any stroke on the background      | above 3.6   | above 6.4   |
  #
  # The table measures the light step text as `#0A0F25`, the light edge
  # label colour.
  #
  # A step class keeps its key order: `fill`, `stroke`, then `text`. A
  # backend adds its own keys after these, so its output keeps one order.
  @light [
    automatic: [fill: "#E8F0FE", stroke: "#1A56DB"],
    manual: [fill: "#FFF4E5", stroke: "#B7791F"],
    wait_state: [fill: "#F3E8FF", stroke: "#6B46C1"],
    done: [fill: "#E6F4EA", stroke: "#1E7B34"],
    failed: [fill: "#FDE8E8", stroke: "#C81E1E"],
    expired: [fill: "#FEF3C7", stroke: "#B45309"],
    end: [fill: "#F3F4F6", stroke: "#4B5563"],
    on_success: [stroke: "#1A56DB"],
    on_error: [stroke: "#C81E1E"],
    timeout: [stroke: "#B45309"],
    undo: [stroke: "#6B7280"]
  ]

  @dark [
    automatic: [fill: "#1E3A8A", stroke: "#93C5FD", text: "#F8FAFC"],
    manual: [fill: "#78350F", stroke: "#FCD34D", text: "#F8FAFC"],
    wait_state: [fill: "#4C1D95", stroke: "#C4B5FD", text: "#F8FAFC"],
    done: [fill: "#14532D", stroke: "#86EFAC", text: "#F8FAFC"],
    failed: [fill: "#7F1D1D", stroke: "#FCA5A5", text: "#F8FAFC"],
    expired: [fill: "#78350F", stroke: "#FCD34D", text: "#F8FAFC"],
    end: [fill: "#1F2937", stroke: "#D1D5DB", text: "#F8FAFC"],
    on_success: [stroke: "#93C5FD"],
    on_error: [stroke: "#FCA5A5"],
    timeout: [stroke: "#FCD34D"],
    undo: [stroke: "#9CA3AF"]
  ]

  @backgrounds %{light: "#FFFFFF", dark: "#1E1E2E"}

  @edge_label_colours %{light: "#0A0F25", dark: "#F8FAFC"}

  @doc """
  The colours of each class, for a theme: a keyword list from the class name
  to its colours. The classes are in this order:

  * `:automatic`, `:manual` and `:wait_state`, for the step kinds.
  * `:done`, `:failed`, `:expired` and `:end`, for terminal steps.
  * `:on_success`, `:on_error`, `:timeout` and `:undo`, for edges.

  A step class has `:fill` and `:stroke`, and an edge class has `:stroke`.
  In the dark theme a step class also has `:text`, the colour of its label.
  """
  @spec colours(theme()) :: keyword(keyword(String.t()))
  def colours(:light), do: @light
  def colours(:dark), do: @dark

  @doc """
  The background colour of a chart, for a theme.
  """
  @spec background(theme()) :: String.t()
  def background(theme) when is_map_key(@backgrounds, theme), do: @backgrounds[theme]

  @doc """
  The colour of the edge label text, for a theme.
  """
  @spec edge_label_colour(theme()) :: String.t()
  def edge_label_colour(theme) when is_map_key(@edge_label_colours, theme),
    do: @edge_label_colours[theme]

  @doc """
  The class of a terminal step, from the kinds of the edges that reach it:
  `:failed` for `on_error` only, `:expired` for timeouts only, `:done` for
  transitions, `on_signal` and `on_success` only, and `:end` for a mix or for no edge.

  Undo edges leave a step and do not count. A step that a person chooses is
  `:done`, whatever its name.
  """
  @spec terminal_class(atom(), Graph.t()) :: :done | :failed | :expired | :end
  def terminal_class(step, %Graph{} = graph) do
    kinds =
      graph.edges
      |> Enum.filter(&(&1.to == step and &1.kind != :undo))
      |> Enum.map(& &1.kind)
      |> Enum.uniq()

    cond do
      kinds == [] -> :end
      kinds == [:on_error] -> :failed
      kinds == [:timeout] -> :expired
      Enum.all?(kinds, &(&1 in [:transition, :on_signal, :on_success])) -> :done
      true -> :end
    end
  end
end
