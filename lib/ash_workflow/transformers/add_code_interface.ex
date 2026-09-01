defmodule AshWorkflow.Transformers.AddCodeInterface do
  @moduledoc """
  Generates code interface definitions for workflow actions.

  Adds `define` entries for each manual step transition — e.g.,
  `define :approve`, `define :reject`.

  These generate convenience functions on the resource module so callers can use
  `CandidatePipeline.approve(record)` instead of `Ash.update` directly.

  Skips definitions that the user has already declared.

  When the workflow declares an `undo` block, also adds `define :undo` and
  injects `undoable?/2` and `undo_target/2` onto the resource module.

  Also injects `state_at/3` and `history/2` directly onto the resource module
  (via `Spark.Dsl.Transformer.eval/3`, not the `code_interface` DSL) when a
  `transition_log` is configured. They are plain functions rather than
  code-interface definitions because `state_at/2` resolves in Elixir by
  walking the log — that has to run the same way on ETS and Postgres, so it
  can't be expressed as a single generated Ash action.
  """
  use Spark.Dsl.Transformer

  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Transformers.AddActions
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

    undo_names =
      if AshWorkflow.Info.undo(dsl), do: [AddActions.undo_action_name()], else: []

    dsl =
      Enum.reduce(transition_names ++ undo_names, dsl, fn name, dsl ->
        maybe_add_define(dsl, name, defined_names)
      end)

    dsl =
      dsl
      |> add_transition_log_functions()
      |> add_undo_functions()

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
            @spec state_at(Ash.Resource.record(), DateTime.t(), Keyword.t()) :: atom() | nil
            def state_at(record, at, opts \\ []),
              do: AshWorkflow.TransitionLog.state_at(record, at, opts)

            @doc """
            Returns this record's transition log rows, ordered by
            `occurred_at` ascending.
            """
            @spec history(Ash.Resource.record(), Keyword.t()) :: [Ash.Resource.record()]
            def history(record, opts \\ []),
              do: AshWorkflow.TransitionLog.history(record, opts)
          end
        )
    end
  end

  defp add_undo_functions(dsl) do
    case AshWorkflow.Info.undo(dsl) do
      nil ->
        dsl

      _undo ->
        Transformer.eval(
          dsl,
          [],
          quote do
            @doc """
            Returns `true` if this record's most recent state change can be
            undone by `actor`.

            Asks the same question the `undo` action asks, without writing.
            Distinct from the code interface's own `can_undo?/2`, which asks
            whether the actor is authorized to call `undo` at all.
            """
            @spec undoable?(Ash.Resource.record(), term()) :: boolean()
            def undoable?(record, actor \\ nil), do: AshWorkflow.Undo.undoable?(record, actor)

            @doc """
            Returns the state `undo` would rewind this record to, or `nil` if
            it cannot be undone.
            """
            @spec undo_target(Ash.Resource.record(), term()) :: atom() | nil
            def undo_target(record, actor \\ nil),
              do: AshWorkflow.Undo.undo_target(record, actor)
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
