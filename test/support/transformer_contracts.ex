defmodule AshWorkflowTest.TransformerContracts do
  @moduledoc """
  The `before?/1` declarations AshWorkflow makes against other extensions'
  transformers, and a checker for them.

  Lives in `test/support` rather than inside the test so that
  `bin/check-transformer-ordering.exs` can run the same checks via `mix run`.
  That matters because the ordering breaking is exactly the kind of failure that
  stops `test/test_helper.exs` from booting at all — AshOban raises on an
  unconfigured queue before ExUnit starts — leaving the test suite unable to
  report the problem it exists to catch.
  """

  @contracts [
    {AshWorkflow.Transformers.AddObanTriggers,
     [
       AshOban.Transformers.SetDefaults,
       AshOban.Transformers.DefineSchedulers,
       AshOban.Transformers.DefineActionWorkers
     ]},
    {AshWorkflow.Transformers.AddStateMachine,
     [
       AshStateMachine.Transformers.AddState,
       AshStateMachine.Transformers.EnsureStateSelected,
       AshStateMachine.Transformers.FillInTransitionDefaults
     ]},
    {AshWorkflow.Transformers.AddActions,
     [
       AshStateMachine.Transformers.AddState,
       AshStateMachine.Transformers.EnsureStateSelected,
       AshStateMachine.Transformers.FillInTransitionDefaults,
       AshOban.Transformers.SetDefaults,
       AshOban.Transformers.DefineSchedulers,
       AshOban.Transformers.DefineActionWorkers
     ]},
    {AshWorkflow.Transformers.AddAttributes, [AshStateMachine.Transformers.AddState]}
  ]

  @doc "The declared `{ours, [theirs]}` pairs."
  def contracts, do: @contracts

  @doc """
  Returns `{ours, theirs, our_position, their_position}` for every contract the
  resource's sorted transformer list violates. An empty list means all hold.
  """
  def violations(resource) do
    sorted =
      resource
      |> Spark.extensions()
      |> Enum.flat_map(& &1.transformers())
      |> Spark.Dsl.Transformer.sort()

    position = fn transformer -> Enum.find_index(sorted, &(&1 == transformer)) end

    for {ours, theirs} <- @contracts,
        them <- theirs,
        ours_at = position.(ours),
        them_at = position.(them),
        is_integer(ours_at),
        is_integer(them_at),
        ours_at > them_at do
      {ours, them, ours_at, them_at}
    end
  end

  @doc "Human-readable explanation of a violation from `violations/1`."
  def explain({ours, them, ours_at, them_at}) do
    """
    #{inspect(ours)} declares `before?(#{inspect(them)})`, \
    but sorted at #{ours_at}, after it at #{them_at}.

    A transformer in another extension has introduced a cycle into the dependency
    graph, and Spark's sort reverses unrelated constraints when that happens.
    """
  end
end
