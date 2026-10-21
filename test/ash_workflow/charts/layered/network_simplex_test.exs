defmodule AshWorkflow.Charts.Layered.NetworkSimplexTest do
  use ExUnit.Case, async: true

  alias AshWorkflow.Charts.Layered.NetworkSimplex

  test "a chain gets ranks minlen apart" do
    assert NetworkSimplex.run([:a, :b, :c], [{:a, :b, 2, 1}, {:b, :c, 2, 1}]) == %{
             a: 0,
             b: 2,
             c: 4
           }
  end

  test "it shortens a heavy edge that longest path leaves long" do
    # a -> b -> c, and d -> c with weight 5. Longest path puts d on rank 0;
    # network simplex moves it to rank 1, next to c.
    ranks = NetworkSimplex.run([:a, :b, :c, :d], [{:a, :b, 1, 1}, {:b, :c, 1, 1}, {:d, :c, 1, 5}])
    assert ranks == %{a: 0, b: 1, c: 2, d: 1}
  end

  test "every edge stays at least minlen long" do
    edges = [{:a, :b, 1, 1}, {:b, :c, 1, 1}, {:c, :d, 1, 1}, {:a, :x, 1, 1}, {:x, :d, 1, 1}]
    ranks = NetworkSimplex.run([:a, :b, :c, :d, :x], edges)

    assert Enum.all?(edges, fn {from, to, minlen, _w} -> ranks[to] - ranks[from] >= minlen end)
    assert %{a: 0, b: 1, c: 2, d: 3} = ranks
  end

  test "each connected component starts at 0" do
    assert NetworkSimplex.run([:a, :b, :c, :d], [{:a, :b, 1, 1}, {:c, :d, 3, 1}]) ==
             %{a: 0, b: 1, c: 0, d: 3}
  end
end
