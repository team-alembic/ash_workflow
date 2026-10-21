defmodule AshWorkflow.Charts.Layered.MetricsTest do
  use ExUnit.Case, async: true

  alias AshWorkflow.Charts.Layered.Metrics
  alias AshWorkflow.Charts.Layered.Result

  # a above b and c; edges a -> b and a -> c, with a label on a -> b.
  defp result(edges) do
    %Result{
      width: 120,
      height: 90,
      direction: :down,
      reversed: MapSet.new(),
      nodes: %{a: {50, 10, 20, 10}, b: {20, 70, 20, 10}, c: {80, 71, 20, 10}},
      edges: edges
    }
  end

  @good %{
    1 => %{points: [{50, 15}, {50, 35}, {20, 40}, {20, 65}], label: {20, 30, 24, 10}},
    2 => %{points: [{50, 15}, {80, 40}, {80, 66}], label: nil}
  }

  test "a clean layout has no hard failures" do
    card = Metrics.scorecard(result(@good))

    assert Metrics.hard_failures(card) == []
    assert card.crossings == 0
    assert card.bends == 3
    assert card.flow == 1.0
    assert card.edge_through_label == 0
    assert card.segments == 5
    assert card.arrow_room == 0
    assert card.jogs == 0
  end

  test "an edge through another edge's label is a hard failure" do
    across = put_in(@good, [2, :points], [{50, 15}, {30, 30}, {80, 56}])
    card = Metrics.scorecard(result(across))

    assert card.edge_through_label == 1
    assert Enum.any?(Metrics.hard_failures(card), &String.starts_with?(&1, "edge_through_label"))
  end

  test "an edge through another node is a hard failure" do
    through = Map.put(@good, 3, %{points: [{20, 75}, {20, 40}, {80, 40}, {80, 76}], label: nil})
    card = Metrics.scorecard(result(through))

    assert card.edge_through_node == 0
    through_c = Map.put(@good, 3, %{points: [{0, 71}, {120, 71}], label: nil})
    assert Metrics.scorecard(result(through_c)).edge_through_node == 2
  end

  test "an arrow on a short or slanted last segment is a hard failure" do
    slanted = put_in(@good, [2, :points], [{50, 15}, {80, 66}])
    short = put_in(@good, [2, :points], [{50, 15}, {80, 60}, {80, 66}])

    assert Metrics.scorecard(result(slanted)).arrow_room == 1
    assert Metrics.scorecard(result(short)).arrow_room == 1
  end

  test "an edge that runs against the flow lowers flow" do
    upward = Map.put(@good, 2, %{points: [{80, 66}, {50, 15}], label: nil})

    assert Metrics.scorecard(result(upward)).flow == 0.5

    assert "flow" in Enum.map(
             Metrics.hard_failures(Metrics.scorecard(result(upward))),
             &hd(String.split(&1, " "))
           )
  end

  test "a label far from its edge is a hard failure" do
    far = put_in(@good, [1, :label], {100, 80, 10, 10})

    assert Metrics.scorecard(result(far)).label_distance > 12
  end
end
