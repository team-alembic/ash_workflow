defmodule AshWorkflowTest.TestScheduler do
  @moduledoc """
  A scheduler that generates nothing and records what it was handed.

  Exists to prove the behaviour is a real surface rather than a hole shaped like
  ash_oban: a resource using this compiles with no AshOban extension, no
  triggers and no Oban, and still describes all of its scheduled work.

  The `Work` list is persisted into the DSL so a test can read it back with
  `Spark.Dsl.Extension.get_persisted/2`, which keeps the capture compile-time
  and avoids any shared runtime state.
  """
  use AshWorkflow.Scheduler

  alias Spark.Dsl.Extension
  alias Spark.Dsl.Transformer

  @impl AshWorkflow.Scheduler
  def transform(dsl, works, opts) do
    dsl =
      dsl
      |> Transformer.persist(:test_scheduler_works, works)
      |> Transformer.persist(:test_scheduler_opts, opts)

    {:ok, dsl}
  end

  @doc "The work this scheduler was handed for a resource."
  def works(resource), do: Extension.get_persisted(resource, :test_scheduler_works)

  @doc "The options this scheduler was configured with."
  def opts(resource), do: Extension.get_persisted(resource, :test_scheduler_opts)
end
