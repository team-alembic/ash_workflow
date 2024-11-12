defmodule AshWorkflow.Transformer do
  use Spark.Dsl.Transformer

  @impl true
  def transform(dsl) do
    {:ok, dsl}
  end
end
