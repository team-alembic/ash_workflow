defmodule AshWorkflow.Expr do
  @moduledoc """
  Expression helpers for workflow DSL options.

  `signal/1` is imported into `on_signal`, so a `filter` can refer to a field
  of the incoming signal with `^signal(:order_id)`.
  """

  @doc """
  A template for the named field of the signal an `on_signal` handler receives.

  AshWorkflow turns each field into an argument of the generated read action,
  so this returns the same template as `Ash.Expr.arg/1`.
  """
  @spec signal(atom()) :: {:_arg, atom()}
  def signal(name) when is_atom(name), do: {:_arg, name}

  @doc """
  The signal fields an expression refers to with `signal/1`, in order of
  first appearance.
  """
  @spec signal_fields(term()) :: [atom()]
  def signal_fields(expression) do
    expression
    |> collect_fields([])
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp collect_fields({:_arg, name}, acc) when is_atom(name), do: [name | acc]

  defp collect_fields(%_{} = struct, acc),
    do: struct |> Map.from_struct() |> Map.values() |> collect_fields(acc)

  defp collect_fields(map, acc) when is_map(map), do: map |> Map.values() |> collect_fields(acc)
  defp collect_fields(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect_fields/2)

  defp collect_fields(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> collect_fields(acc)

  defp collect_fields(_other, acc), do: acc
end
