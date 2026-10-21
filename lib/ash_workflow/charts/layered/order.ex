defmodule AshWorkflow.Charts.Layered.Order do
  @moduledoc false
  # Orders the nodes of each rank to reduce edge crossings: a depth-first
  # start, then barycenter sweeps that alternate down and up, each followed by
  # adjacent swaps. Keeps the best order it sees. The graphs are small, so the
  # crossing count is a plain pairwise count.

  def run(graph, sweeps) do
    max_rank = graph.ranks |> Map.values() |> Enum.max(fn -> 0 end)
    preds = Enum.group_by(graph.segments, &elem(&1, 1), &elem(&1, 0))
    succs = Enum.group_by(graph.segments, &elem(&1, 0), &elem(&1, 1))
    start = initial(graph, succs, max_rank)

    {_last, best} =
      Enum.reduce(1..sweeps//1, {start, {start, crossings(start, succs)}}, fn i, {layers, best} ->
        layers =
          if rem(i, 2) == 1,
            do: sweep(layers, 1..max_rank//1, preds, -1),
            else: sweep(layers, (max_rank - 1)..0//-1, succs, 1)

        layers = transpose(layers, succs)
        count = crossings(layers, succs)
        {layers, if(count < elem(best, 1), do: {layers, count}, else: best)}
      end)

    best
  end

  defp initial(graph, succs, max_rank) do
    empty = Map.new(0..max_rank, &{&1, []})

    {layers, _seen} =
      Enum.reduce(graph.ids, {empty, MapSet.new()}, fn id, acc -> dfs(id, graph, succs, acc) end)

    Map.new(layers, fn {rank, ids} -> {rank, Enum.reverse(ids)} end)
  end

  defp dfs(id, graph, succs, {layers, seen} = acc) do
    if MapSet.member?(seen, id) do
      acc
    else
      rank = Map.fetch!(graph.ranks, id)
      acc = {Map.update!(layers, rank, &[id | &1]), MapSet.put(seen, id)}
      succs |> Map.get(id, []) |> Enum.reduce(acc, &dfs(&1, graph, succs, &2))
    end
  end

  # Sorts each rank by the mean position of its neighbours in the rank before
  # it in this sweep. A node with no neighbour there keeps its own index.
  defp sweep(layers, ranks, neighbours, step) do
    Enum.reduce(ranks, layers, fn rank, layers ->
      fixed = index(Map.fetch!(layers, rank + step))

      sorted =
        layers
        |> Map.fetch!(rank)
        |> Enum.with_index()
        |> Enum.map(fn {id, i} ->
          positions = for n <- Map.get(neighbours, id, []), Map.has_key?(fixed, n), do: fixed[n]

          case positions do
            [] -> {i, i, id}
            _ -> {Enum.sum(positions) / length(positions), i, id}
          end
        end)
        |> Enum.sort()
        |> Enum.map(&elem(&1, 2))

      Map.put(layers, rank, sorted)
    end)
  end

  defp transpose(layers, succs) do
    improved =
      layers
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce(layers, fn rank, layers ->
        Enum.reduce(0..(length(Map.fetch!(layers, rank)) - 2)//1, layers, fn i, layers ->
          candidate = Map.update!(layers, rank, &swap(&1, i))

          if crossings(candidate, succs) < crossings(layers, succs),
            do: candidate,
            else: layers
        end)
      end)

    if improved == layers, do: layers, else: transpose(improved, succs)
  end

  defp swap(list, i) do
    {before, [x, y | rest]} = Enum.split(list, i)
    before ++ [y, x | rest]
  end

  def crossings(layers, succs) do
    ranks = layers |> Map.keys() |> Enum.sort()

    ranks
    |> Enum.zip(Enum.drop(ranks, 1))
    |> Enum.map(fn {upper, lower} ->
      pairs(Map.fetch!(layers, upper), Map.fetch!(layers, lower), succs)
    end)
    |> Enum.sum()
  end

  defp pairs(upper, lower, succs) do
    lower_index = index(lower)

    segments =
      for {id, i} <- Enum.with_index(upper),
          to <- Map.get(succs, id, []),
          Map.has_key?(lower_index, to),
          do: {i, lower_index[to]}

    Enum.count(for {a1, b1} <- segments, {a2, b2} <- segments, a1 < a2 and b1 > b2, do: :x)
  end

  defp index(ids), do: ids |> Enum.with_index() |> Map.new()
end
