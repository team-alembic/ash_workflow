defmodule AshWorkflow.Transformers.AddCodeInterface do
  @moduledoc """
  Generates code interface definitions for workflow actions.

  Adds `define` entries for each manual step transition — e.g.,
  `define :approve`, `define :reject`.

  These generate convenience functions on the resource module so callers can use
  `CandidatePipeline.approve(record)` instead of `Ash.update` directly.

  Skips definitions that the user has already declared.

  Also injects `state_at/2` and `history/1` directly onto the resource module
  (via `Spark.Dsl.Transformer.eval/3`, not the `code_interface` DSL) when a
  `transition_log` is configured. They are plain functions rather than
  code-interface definitions because `state_at/2` resolves in Elixir by
  walking the log — that has to run the same way on ETS and Postgres, so it
  can't be expressed as a single generated Ash action.
  """
  use Spark.Dsl.Transformer

  alias AshWorkflow.Entities.Step
  alias Spark.Dsl.Transformer

  def transform(dsl) do
    steps =
      dsl
      |> Transformer.get_entities([:workflow])
      |> Enum.filter(&match?(%Step{}, &1))

    existing_defines = Transformer.get_entities(dsl, [:code_interface])
    defined_names = MapSet.new(existing_defines, & &1.name)

    transition_names =
      steps
      |> Enum.filter(&Step.manual?/1)
      |> Enum.flat_map(& &1.transitions)
      |> Enum.map(& &1.name)
      |> Enum.uniq()

    dsl =
      Enum.reduce(transition_names, dsl, fn name, dsl ->
        maybe_add_define(dsl, name, defined_names)
      end)

    dsl = add_transition_log_functions(dsl)

    {:ok, dsl}
  end

  defp add_transition_log_functions(dsl) do
    case AshWorkflow.Info.transition_log(dsl) do
      nil ->
        dsl

      _log ->
        Transformer.eval(
          dsl,
          [],
          quote do
            @doc """
            Returns the state this record was in at `at`, resolved from its
            transition log. Returns `nil` if `at` predates the earliest logged
            row.
            """
            @spec state_at(Ash.Resource.record(), DateTime.t()) :: atom() | nil
            def state_at(record, at), do: AshWorkflow.TransitionLog.state_at(record, at)

            @doc """
            Returns this record's transition log rows, ordered by
            `occurred_at` ascending.
            """
            @spec history(Ash.Resource.record()) :: [Ash.Resource.record()]
            def history(record), do: AshWorkflow.TransitionLog.history(record)
          end
        )
    end
  end

  defp maybe_add_define(dsl, name, defined_names) do
    if MapSet.member?(defined_names, name) do
      dsl
    else
      define =
        Transformer.build_entity!(Ash.Resource.Dsl, [:code_interface], :define, name: name)

      Transformer.add_entity(dsl, [:code_interface], define)
    end
  end

  def after?(_), do: true
end
