defmodule AshWorkflow.Charts.LayeredTest do
  use ExUnit.Case, async: true

  alias AshWorkflow.Charts.Layered
  alias AshWorkflow.Charts.Layered.Acyclic
  alias AshWorkflow.Charts.Layered.Edge
  alias AshWorkflow.Charts.Layered.Node
  alias AshWorkflow.Charts.Layered.Normalize
  alias AshWorkflow.Charts.Layered.Order
  alias AshWorkflow.Charts.Layered.Rank

  defp box(id, w \\ 40, h \\ 20), do: %Node{id: id, width: w, height: h}

  defp edge(id, from, to, lw \\ 0, lh \\ 0),
    do: %Edge{id: id, from: from, to: to, label_width: lw, label_height: lh}

  test "Acyclic reverses the edge that closes a cycle, and only that edge" do
    nodes = [box(:a), box(:b), box(:c)]
    edges = [edge(1, :a, :b), edge(2, :b, :c), edge(3, :c, :a)]

    {dag, reversed} = Acyclic.run(nodes, edges)

    assert reversed == MapSet.new([3])
    assert Enum.find(dag, &(&1.id == 3)) |> Map.take([:from, :to]) == %{from: :a, to: :c}
  end

  test "Rank puts each node two ranks below its furthest predecessor" do
    nodes = [box(:a), box(:b), box(:c)]
    edges = [edge(1, :a, :b), edge(2, :b, :c), edge(3, :a, :c)]

    assert Rank.run(nodes, edges) == %{a: 0, b: 2, c: 4}
  end

  test "Normalize puts one dummy on each rank an edge crosses, and the label on the middle one" do
    nodes = [box(:a), box(:b)]
    edges = [edge(1, :a, :b, 30, 16)]
    graph = Normalize.run(nodes, edges, %{a: 0, b: 4})

    assert graph.chains[1] == [:a, {:dummy, 1, 1}, {:dummy, 1, 2}, {:dummy, 1, 3}, :b]
    assert graph.nodes[{:dummy, 1, 2}] == %{width: 30, height: 16, dummy: :label}
    assert graph.nodes[{:dummy, 1, 1}] == %{width: 0, height: 0, dummy: :edge}
  end

  test "Order removes the crossing of two edges drawn in the wrong order" do
    # The depth-first start visits c and d first, so rank 2 is [c, d] while
    # rank 0 is [a, b]: a -> d and b -> c cross once.
    nodes = [box(:c), box(:d), box(:a), box(:b)]
    edges = [edge(1, :a, :d), edge(2, :b, :c)]
    ranks = %{a: 0, b: 0, c: 2, d: 2}
    graph = Normalize.run(nodes, edges, ranks)

    assert {_layers, 1} = Order.run(graph, 0)
    assert {_layers, 0} = Order.run(graph, 4)
  end

  test "layout gives a chain one column, top to bottom, with no overlap" do
    nodes = [box(:a), box(:b), box(:c)]
    edges = [edge(1, :a, :b, 30, 16), edge(2, :b, :c, 30, 16)]

    result = Layered.layout(nodes, edges)

    {ax, ay, _, _} = result.nodes[:a]
    {bx, by, _, _} = result.nodes[:b]
    {cx, cy, _, _} = result.nodes[:c]
    assert ay < by and by < cy
    assert_in_delta ax, bx, 20
    assert_in_delta bx, cx, 20
    assert result.crossings == 0
  end

  test "a reversed edge still runs from its source to its target" do
    nodes = [box(:a), box(:b)]
    edges = [edge(1, :a, :b), edge(2, :b, :a)]

    result = Layered.layout(nodes, edges)

    {_, ay, _, ah} = result.nodes[:a]
    {_, by, _, bh} = result.nodes[:b]
    [{_, first_y} | _] = result.edges[2].points
    {_, last_y} = List.last(result.edges[2].points)
    assert first_y == by - bh / 2
    assert last_y == ay + ah / 2
  end

  test "a self-loop gets a loop on the right of its node and a label" do
    nodes = [box(:a)]
    edges = [edge(1, :a, :a, 30, 16)]

    result = Layered.layout(nodes, edges)

    {ax, _, aw, _} = result.nodes[:a]
    assert Enum.all?(result.edges[1].points, fn {x, _} -> x >= ax + aw / 2 end)
    assert {_, _, 30, 16} = result.edges[1].label
  end

  test "greedy cycle breaking reverses one edge of a two-cycle, the later one in the input" do
    nodes = [box(:a), box(:b)]
    edges = [edge(1, :a, :b), edge(2, :b, :a)]

    assert {_dag, reversed} = Acyclic.run(nodes, edges, :greedy)
    assert reversed == MapSet.new([2])
  end

  test "the weighted median ignores an outlier that the mean follows" do
    assert Order.median_value([0, 1, 9]) == 1
    assert Order.median_value([2]) == 2
    assert Order.median_value([]) == nil
    assert Order.median_value([0, 4]) == 2.0
  end

  test "without lanes, a companion edge is left out and takes no room" do
    nodes = [box(:a), box(:b)]
    forward = edge(1, :a, :b, 30, 16)
    undo = %{edge(2, :b, :a) | companion: 1}

    alone = Layered.layout(nodes, [forward])
    paired = Layered.layout(nodes, [forward, undo], companions: :none)

    assert paired.nodes == alone.nodes
    refute Map.has_key?(paired.edges, 2)
  end

  test "the right direction runs a chain left to right, and keeps box and label sizes" do
    nodes = [box(:a, 60, 20), box(:b, 60, 20), box(:c, 60, 20)]
    edges = [edge(1, :a, :b, 30, 16), edge(2, :b, :c, 30, 16)]

    right = Layered.layout(nodes, edges, direction: :right)

    {ax, ay, aw, ah} = right.nodes[:a]
    {bx, by, _, _} = right.nodes[:b]
    assert {aw, ah} == {60, 20}
    assert ax < bx
    assert_in_delta ay, by, 1
    assert {_lx, _ly, 30, 16} = right.edges[1].label
    assert Enum.all?(right.edges[1].points, fn {_x, y} -> abs(y - ay) < 1 end)
  end

  test "an edge that turns at once leaves from the middle part of its box, not a corner" do
    nodes = [box(:a, 60), box(:b), box(:c), box(:d)]
    edges = [edge(1, :a, :b, 200, 60), edge(2, :a, :c, 200, 60), edge(3, :a, :d, 200, 60)]

    result = Layered.layout(nodes, edges)
    {ax, _, aw, _} = result.nodes[:a]

    for id <- [1, 2, 3] do
      [{px, _} | rest] = result.edges[id].points
      straight? = Enum.all?(rest, fn {x, _} -> x == px end)
      assert straight? or abs(px - ax) <= 0.3 * aw
    end
  end

  test "a label over its edge is centred on the edge; an orthogonal edge passes it straight" do
    nodes = [box(:a, 40), box(:b, 160), box(:c, 40)]
    edges = [edge(1, :a, :b), edge(2, :a, :c, 120, 20)]

    for routing <- [:polyline, :orthogonal] do
      result = Layered.layout(nodes, edges, labels: :over, routing: routing)
      %{points: points, label: {lx, ly, w, h}} = result.edges[2]

      inside? = fn {x, y} -> x > lx and x < lx + w and y > ly - h / 2 and y < ly + h / 2 end

      # Where the edge crosses the label's middle height.
      crossing =
        points
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.find_value(fn [{x1, y1}, {x2, y2}] ->
          if min(y1, y2) <= ly and ly <= max(y1, y2) and y1 != y2,
            do: x1 + (x2 - x1) * (ly - y1) / (y2 - y1)
        end)

      assert inside?.({crossing, ly})
      if routing == :polyline, do: assert(crossing == lx + w / 2)

      # The orthogonal edge does not turn behind its label: it enters and
      # leaves the label on one vertical line.
      turns = points |> Enum.drop(1) |> Enum.drop(-1)
      assert routing == :polyline or not Enum.any?(turns, inside?)
    end
  end

  test "a lane companion runs in its own lane, at least 24 px left of its partner" do
    nodes = [box(:a), box(:b)]
    forward = edge(1, :a, :b, 30, 16)
    undo = %{edge(2, :b, :a) | companion: 1}

    paired = Layered.layout(nodes, [forward, undo], companions: :lanes)
    {_, ay, _, ah} = paired.nodes[:a]
    {_, by, _, bh} = paired.nodes[:b]

    # The lane in the label rank: where the edge crosses the middle height
    # between the two boxes.
    mid = (ay + ah / 2 + by - bh / 2) / 2

    lane = fn id ->
      paired.edges[id].points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find_value(fn [{x1, y1}, {x2, y2}] ->
        if min(y1, y2) <= mid and mid <= max(y1, y2) and y1 != y2,
          do: x1 + (x2 - x1) * (mid - y1) / (y2 - y1)
      end)
    end

    assert lane.(1) - lane.(2) >= 24
    assert MapSet.member?(paired.reversed, 2)
  end

  test "the same input gives the same result" do
    nodes = [box(:a), box(:b), box(:c), box(:d)]

    edges = [
      edge(1, :a, :b, 20, 10),
      edge(2, :a, :c),
      edge(3, :b, :d),
      edge(4, :c, :d),
      edge(5, :d, :a)
    ]

    assert Layered.layout(nodes, edges) == Layered.layout(nodes, edges)
  end
end
