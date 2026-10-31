defmodule AshWorkflow.Charts.Layered do
  @moduledoc false
  # Spike: a layered (Sugiyama) layout for small directed graphs. No Ash
  # dependency, so it can move to its own package.

  defmodule Node do
    @moduledoc false
    defstruct [:id, width: 0, height: 0]
    @type t :: %__MODULE__{id: term(), width: number(), height: number()}
  end

  defmodule Edge do
    @moduledoc false
    defstruct [:id, :from, :to, label_width: 0, label_height: 0, companion: nil]

    @type t :: %__MODULE__{
            id: term(),
            from: term(),
            to: term(),
            label_width: number(),
            label_height: number()
          }
  end

  defmodule Result do
    @moduledoc false
    defstruct width: 0,
              height: 0,
              crossings: 0,
              nodes: %{},
              edges: %{},
              reversed: MapSet.new(),
              direction: :down,
              routing: :polyline,
              loops: MapSet.new()

    @type t :: %__MODULE__{}
  end

  alias __MODULE__.{Acyclic, NetworkSimplex, Normalize, Order, Position, Rank, Route}

  @defaults [
    rank_sep: 48,
    node_sep: 32,
    edge_sep: 12,
    margin: 16,
    sweeps: 8,
    passes: 8,
    ranker: :network_simplex,
    acyclic: :dfs,
    heuristic: :mean_index,
    tie: :current,
    placement: :network_simplex,
    companions: :lanes,
    labels: :beside
  ]

  @spec layout([Node.t()], [Edge.t()], keyword()) :: Result.t()
  def layout(nodes, edges, opts \\ []) do
    opts = Keyword.merge(@defaults, opts)
    right? = opts[:direction] == :right

    # The right direction lays out the problem mirrored on the diagonal, as
    # if it ran down, and mirrors the result back.
    {nodes, edges} =
      if right?,
        do: {Enum.map(nodes, &swap_node/1), Enum.map(edges, &swap_edge/1)},
        else: {nodes, edges}

    {companions, edges} = Enum.split_with(edges, &(&1.companion != nil))
    {loops, edges} = Enum.split_with(edges, &(&1.from == &1.to))
    {dag, reversed} = Acyclic.run(nodes, edges, opts[:acyclic])

    # Companion edges (an undo beside the move it rewinds): with :lanes, each
    # gets its own lane, one gap beside its partner's; otherwise they are
    # left out, and the caller marks the partner instead.
    lane_companions = if opts[:companions] == :lanes, do: companions, else: []

    # A lane companion runs the same way as its partner in the layered graph,
    # so it covers the same ranks.
    partner_dag = Map.new(dag, &{&1.id, &1})

    {dag, reversed} =
      Enum.reduce(lane_companions, {dag, reversed}, fn c, {dag, reversed} ->
        p = Map.fetch!(partner_dag, c.companion)
        reversed = if c.from != p.from, do: MapSet.put(reversed, c.id), else: reversed
        {dag ++ [%{c | from: p.from, to: p.to}], reversed}
      end)

    ranks =
      case opts[:ranker] do
        :network_simplex ->
          NetworkSimplex.run(Enum.map(nodes, & &1.id), Enum.map(dag, &{&1.from, &1.to, 2, 1}))

        _longest_path ->
          Rank.run(nodes, dag)
      end

    graph = Normalize.run(nodes, dag, ranks)
    {layers, crossings} = Order.run(graph, opts[:sweeps], opts)
    graph = label_sides(graph, layers, opts[:labels])
    {layers, pairs} = pair_companions(layers, graph, lane_companions)
    opts = Keyword.put(opts, :pairs, pairs)
    {coords, lanes, ports} = Position.run(graph, layers, opts)
    opts = Keyword.merge(opts, lanes: lanes, ports: ports)

    result =
      graph
      |> Route.run(coords, reversed, loops, opts)

    result = if right?, do: transpose(result), else: result

    %{
      result
      | crossings: crossings,
        direction: Keyword.get(opts, :direction, :down),
        routing: Keyword.get(opts, :routing, :polyline)
    }
  end

  defp flip1({x, y}), do: {y, x}

  # A label sits beside its edge's lane. In a row with several labels, the
  # left half sit left of their lanes and the rest right, so the lanes of the
  # row gather towards its middle, under the boxes they leave, and fewer
  # edges swing out past a box's corner.
  #
  # With labels: :over, every label sits centred over its own lane, and the
  # lane runs behind it.
  defp label_sides(graph, layers, mode) do
    Enum.reduce(layers, graph, fn {_rank, ids}, graph ->
      labels = Enum.filter(ids, &(graph.nodes[&1].dummy == :label))

      sides =
        if mode == :over,
          do: Enum.map(labels, &{&1, :over}),
          else: Enum.map(Enum.take(labels, div(length(labels), 2)), &{&1, :left})

      nodes =
        Enum.reduce(sides, graph.nodes, fn {id, side}, nodes ->
          Map.update!(nodes, id, &Map.put(&1, :side, side))
        end)

      %{graph | nodes: nodes}
    end)
  end

  # Each lane companion's dummy goes just left of its partner's dummy in the
  # same rank, and the pairs go to x placement, which keeps the two lanes one
  # gap apart.
  defp pair_companions(layers, graph, companions) do
    Enum.reduce(companions, {layers, []}, fn c, {layers, pairs} ->
      graph.chains
      |> Map.fetch!(c.id)
      |> Enum.slice(1..-2//1)
      |> Enum.reduce({layers, pairs}, fn {:dummy, _id, rank} = dummy, {layers, pairs} ->
        partner = {:dummy, c.companion, rank}
        layer = List.delete(Map.fetch!(layers, rank), dummy)
        at = Enum.find_index(layer, &(&1 == partner))
        {Map.put(layers, rank, List.insert_at(layer, at, dummy)), [{dummy, partner} | pairs]}
      end)
    end)
  end

  defp swap_node(node), do: %{node | width: node.height, height: node.width}

  defp swap_edge(edge),
    do: %{edge | label_width: edge.label_height, label_height: edge.label_width}

  # Mirror on the diagonal: x and y swap, and so do widths and heights. A
  # label box is {left_x, centre_y, w, h}, so its corners move too; a label
  # right of a downward edge ends up under a rightward one.
  defp transpose(%Result{} = r) do
    %{
      r
      | width: r.height,
        height: r.width,
        nodes: Map.new(r.nodes, fn {id, {x, y, w, h}} -> {id, {y, x, h, w}} end),
        edges:
          Map.new(r.edges, fn {id, e} ->
            label =
              case e.label do
                nil -> nil
                {lx, ly, w, h} -> {ly - h / 2, lx + w / 2, h, w}
              end

            flip = fn points -> Enum.map(points, fn {x, y} -> {y, x} end) end

            e =
              if Map.has_key?(e, :curve),
                do: %{
                  e
                  | curve:
                      Enum.map(e.curve, fn
                        {kind, a, b} -> {kind, flip1(a), flip1(b)}
                        {kind, a, c1, c2, b} -> {kind, flip1(a), flip1(c1), flip1(c2), flip1(b)}
                      end)
                },
                else: e

            {id, %{e | points: flip.(e.points), label: label}}
          end)
    }
  end
end
