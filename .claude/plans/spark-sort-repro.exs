defmodule M do
  defmodule AddObanTriggers do
    use Spark.Dsl.Transformer
    def before?(M.SetDefaults), do: true
    def before?(_), do: false
    def transform(d), do: {:ok, d}
  end

  defmodule SetDefaults do
    use Spark.Dsl.Transformer
    def after?(_), do: true
    def transform(d), do: {:ok, d}
  end

  defmodule AddState do
    use Spark.Dsl.Transformer
    def before?(M.DefaultAccept), do: true
    def before?(_), do: false
    def after?(M.DefaultAccept), do: false
    def after?(_), do: true
    def transform(d), do: {:ok, d}
  end

  defmodule DefaultAccept do
    use Spark.Dsl.Transformer
    def after?(_), do: false
    def transform(d), do: {:ok, d}
  end

  # as declared on the temporal branch
  defmodule ATRF do
    use Spark.Dsl.Transformer
    def after?(M.DefaultAccept), do: true
    def after?(_), do: false
    def transform(d), do: {:ok, d}
  end

  # with the DefaultAccept edge dropped
  defmodule ATRFNarrowed do
    use Spark.Dsl.Transformer
    def after?(_), do: false
    def transform(d), do: {:ok, d}
  end
end

check = fn list, label ->
  s = Spark.Dsl.Transformer.sort(list)
  a = Enum.find_index(s, &(&1 == M.AddObanTriggers))
  d = Enum.find_index(s, &(&1 == M.SetDefaults))
  IO.puts("#{label}: AddObanTriggers=#{a} SetDefaults=#{d} -> #{if a < d, do: "OK", else: "VIOLATED"}")
end

base = [M.AddObanTriggers, M.SetDefaults, M.AddState, M.DefaultAccept]
check.(base, "without ATRF          ")
check.(base ++ [M.ATRF], "with ATRF (as-is)    ")
check.(base ++ [M.ATRFNarrowed], "with ATRF narrowed   ")
