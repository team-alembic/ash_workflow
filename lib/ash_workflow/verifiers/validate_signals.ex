defmodule AshWorkflow.Verifiers.ValidateSignals do
  @moduledoc """
  Verifies that every `emit` names an `:after_action` signal of the workflow's
  `signals` module, and that the signal's fields can all be filled.

  A required signal field is filled by a workflow field (`from_state`,
  `to_state`, `transition_name`, `triggered_by`, `occurred_at`), by a resource
  attribute of the same name, or by the emit's `fields` or `values`.
  """
  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: ResourceInfo
  alias Ash.Signals.Info, as: SignalsInfo
  alias AshWorkflow.Entities.Emit
  alias AshWorkflow.Entities.Step
  alias Spark.Dsl.Entity
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @workflow_fields [:from_state, :to_state, :transition_name, :triggered_by, :occurred_at]

  @impl true
  def verify(dsl) do
    module = Verifier.get_persisted(dsl, :module)
    signals = Verifier.get_option(dsl, [:workflow], :signals)

    with :ok <- validate_signals_module(module, signals, emits(dsl)) do
      Enum.reduce_while(emits(dsl), :ok, &continue_validating(dsl, module, signals, &1, &2))
    end
  end

  defp continue_validating(dsl, module, signals, {path, emit}, :ok) do
    case validate_emit(dsl, module, signals, path, emit) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp emits(dsl) do
    entities = Verifier.get_entities(dsl, [:workflow])

    workflow_emits =
      for %Emit{} = emit <- entities, do: {[:workflow, :emit, emit.name], emit}

    step_emits =
      for %Step{} = step <- entities,
          {path, emit} <- step_emits(step),
          do: {[:workflow, :step, step.name | path], emit}

    workflow_emits ++ step_emits
  end

  defp step_emits(step) do
    nested = fn kind, entities ->
      for entity <- entities,
          emit <- entity.emits,
          do: {[kind, entity.name, :emit, emit.name], emit}
    end

    Enum.map(step.emits, &{[:emit, &1.name], &1}) ++
      nested.(:transition, step.transitions) ++
      nested.(:timeout, step.timeouts) ++
      nested.(:every, step.everys) ++ nested.(:on_signal, step.on_signals)
  end

  defp validate_signals_module(_module, _signals, []), do: :ok

  defp validate_signals_module(module, nil, [{path, emit} | _]) do
    error(
      module,
      path,
      emit,
      "emit :#{emit.name} needs the workflow to name its signals module with `signals MyApp.Signals`."
    )
  end

  defp validate_signals_module(module, signals, [{path, emit} | _]) do
    if Code.ensure_loaded?(signals) and Spark.Dsl.is?(signals, Ash.Signals) do
      :ok
    else
      error(module, path, emit, "`signals #{inspect(signals)}` is not an `Ash.Signals` module.")
    end
  end

  defp validate_emit(dsl, module, signals, path, emit) do
    case SignalsInfo.signal(signals, emit.name) do
      nil ->
        error(module, path, emit, "`#{inspect(signals)}` has no signal named :#{emit.name}.")

      %{phase: phase} when phase != :after_action ->
        error(
          module,
          path,
          emit,
          "Signal :#{emit.name} is emitted during #{inspect(phase)}, but workflows only emit " <>
            ":after_action signals for now."
        )

      signal ->
        with :ok <- validate_mapping(dsl, module, path, emit, signal),
             :ok <- validate_required(dsl, module, path, emit, signal) do
          validate_state_types(module, path, emit, signal)
        end
    end
  end

  defp validate_mapping(dsl, module, path, emit, signal) do
    signal_fields = Enum.map(signal.arguments, & &1.name)

    unknown =
      for {option, mapping} <- [fields: emit.fields, values: emit.values],
          {name, _} <- mapping,
          name not in signal_fields,
          do: {option, name}

    not_attributes =
      for {name, attribute} <- emit.fields,
          ResourceInfo.attribute(dsl, attribute) == nil,
          do: {name, attribute}

    case {unknown, not_attributes} do
      {[{option, name} | _], _} ->
        error(
          module,
          path,
          emit,
          "emit :#{emit.name} `#{option}` sets #{inspect(name)}, but signal :#{signal.name} " <>
            "has no field with that name."
        )

      {[], [{name, attribute} | _]} ->
        error(
          module,
          path,
          emit,
          "emit :#{emit.name} `fields` maps #{inspect(name)} to #{inspect(attribute)}, " <>
            "which is not an attribute of the resource."
        )

      {[], []} ->
        :ok
    end
  end

  defp validate_required(dsl, module, path, emit, signal) do
    fillable =
      @workflow_fields ++ Keyword.keys(emit.fields) ++ Keyword.keys(emit.values)

    missing =
      Enum.find(signal.arguments, fn argument ->
        argument.allow_nil? == false and is_nil(argument.default) and
          argument.name not in fillable and ResourceInfo.attribute(dsl, argument.name) == nil
      end)

    if missing do
      error(
        module,
        path,
        emit,
        "Signal :#{signal.name} requires #{inspect(missing.name)}, which emit :#{emit.name} " <>
          "does not fill. Add an attribute named #{inspect(missing.name)} to the resource, " <>
          "map it with `fields: [#{missing.name}: :attribute]`, or set it with " <>
          "`values: [#{missing.name}: value]`."
      )
    else
      :ok
    end
  end

  defp validate_state_types(module, path, emit, signal) do
    wrong =
      Enum.find(signal.arguments, fn argument ->
        argument.name in [:from_state, :to_state] and
          Ash.Type.get_type(argument.type) != Ash.Type.Atom
      end)

    if wrong do
      error(
        module,
        path,
        emit,
        "Signal :#{signal.name} declares #{inspect(wrong.name)} as #{inspect(wrong.type)}, " <>
          "but the workflow fills it with a step name, so it must be :atom."
      )
    else
      :ok
    end
  end

  defp error(module, path, emit, message) do
    {:error,
     DslError.exception(
       module: module,
       path: path,
       message: message,
       location: Entity.anno(emit)
     )}
  end
end
