defmodule AshWorkflow.Verifiers.ValidateOnSignal do
  @moduledoc """
  Verifies that every `on_signal` names a signal its module declares, selects
  records from that signal's fields, and has exactly one valid outcome.
  """
  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: ResourceInfo
  alias Ash.Signals.Info, as: SignalsInfo
  alias AshWorkflow.Entities.Step
  alias Spark.Dsl.Entity
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    module = Verifier.get_persisted(dsl, :module)
    steps = for %Step{} = step <- Verifier.get_entities(dsl, [:workflow]), do: step
    step_names = Enum.map(steps, & &1.name)
    workflow_signals = Verifier.get_option(dsl, [:workflow], :signals)

    handlers = for step <- steps, on_signal <- step.on_signals, do: {step, on_signal}

    Enum.reduce_while(handlers, :ok, fn {step, on_signal}, :ok ->
      context = %{
        dsl: dsl,
        module: module,
        step: step,
        step_names: step_names,
        steps: steps,
        path: [:workflow, :step, step.name, :on_signal, on_signal.name],
        on_signal: on_signal
      }

      case validate(context, on_signal.from || workflow_signals) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate(context, signal_module) do
    with :ok <- validate_step(context),
         {:ok, signal} <- validate_signal(context, signal_module),
         :ok <- validate_selector(context, signal) do
      validate_outcome(context)
    end
  end

  defp validate_step(%{step: %{terminal: true}} = context) do
    error(
      context,
      "on_signal :#{context.on_signal.name} is declared on terminal step :#{context.step.name}, " <>
        "which nothing leaves."
    )
  end

  defp validate_step(_context), do: :ok

  defp validate_signal(context, nil) do
    error(
      context,
      "on_signal :#{context.on_signal.name} needs a signals module. Set `from MyApp.Signals` " <>
        "on the handler, or `signals MyApp.Signals` on the workflow."
    )
  end

  defp validate_signal(context, signal_module) do
    name = context.on_signal.name

    cond do
      !(Code.ensure_loaded?(signal_module) and Spark.Dsl.is?(signal_module, Ash.Signals)) ->
        error(context, "`#{inspect(signal_module)}` is not an `Ash.Signals` module.")

      signal = SignalsInfo.signal(signal_module, name) ->
        {:ok, signal}

      true ->
        error(context, "`#{inspect(signal_module)}` has no signal named :#{name}.")
    end
  end

  defp validate_selector(%{on_signal: %{filter: nil, read_action: nil}} = context, _signal) do
    error(
      context,
      "on_signal :#{context.on_signal.name} must declare either `filter` or `read_action`."
    )
  end

  defp validate_selector(%{on_signal: %{read_action: nil}} = context, signal) do
    fields = Enum.map(signal.arguments, & &1.name)

    case Enum.reject(AshWorkflow.Expr.signal_fields(context.on_signal.filter), &(&1 in fields)) do
      [] ->
        :ok

      [field | _] ->
        error(
          context,
          "on_signal :#{context.on_signal.name} `filter` uses `signal(#{inspect(field)})`, " <>
            "but signal :#{signal.name} has no field with that name."
        )
    end
  end

  defp validate_selector(%{on_signal: %{filter: nil}} = context, signal) do
    %{on_signal: on_signal} = context

    case ResourceInfo.action(context.dsl, on_signal.read_action) do
      %{type: :read} = read_action ->
        fields = Enum.map(signal.arguments, & &1.name)

        case Enum.reject(read_action.arguments, &(&1.name in fields)) do
          [] ->
            :ok

          [argument | _] ->
            error(
              context,
              "on_signal :#{on_signal.name} `read_action` :#{read_action.name} takes " <>
                "argument #{inspect(argument.name)}, but signal :#{signal.name} has no field " <>
                "with that name to set it from."
            )
        end

      _ ->
        error(
          context,
          "on_signal :#{on_signal.name} `read_action` :#{on_signal.read_action} is not a read " <>
            "action of the resource."
        )
    end
  end

  defp validate_selector(context, _signal) do
    error(
      context,
      "on_signal :#{context.on_signal.name} declares both `filter` and `read_action`. " <>
        "Declare one."
    )
  end

  defp validate_outcome(%{on_signal: %{transition_to: nil, action: nil}} = context) do
    error(
      context,
      "on_signal :#{context.on_signal.name} must declare either `transition_to` or `action`."
    )
  end

  defp validate_outcome(%{on_signal: %{action: nil, transition_to: target}} = context) do
    if target in context.step_names do
      :ok
    else
      error(
        context,
        "on_signal :#{context.on_signal.name} transitions to :#{target}, which is not a step " <>
          "of the workflow."
      )
    end
  end

  defp validate_outcome(%{on_signal: %{transition_to: nil, action: action}} = context) do
    case ResourceInfo.action(context.dsl, action) do
      %{type: :update} ->
        validate_action_not_scheduled(context)

      _ ->
        error(
          context,
          "on_signal :#{context.on_signal.name} runs :#{action}, which is not an update " <>
            "action of the resource."
        )
    end
  end

  defp validate_outcome(context) do
    error(
      context,
      "on_signal :#{context.on_signal.name} declares both `transition_to` and `action`. " <>
        "Declare one."
    )
  end

  # A timeout or `every` appends its own `RecordEvent` to the action it names,
  # so sharing that action with a handler would log one run twice. Handlers
  # sharing an action are fine: they get one `RecordEvent` between them.
  defp validate_action_not_scheduled(%{on_signal: %{action: action}} = context) do
    scheduled =
      for step <- context.steps,
          entry <- step.timeouts ++ step.everys,
          entry.action == action,
          do: {step, entry}

    case scheduled do
      [] ->
        :ok

      [{step, entry} | _] ->
        kind = if match?(%AshWorkflow.Entities.Every{}, entry), do: "every", else: "timeout"

        error(
          context,
          "on_signal :#{context.on_signal.name} runs :#{action}, which #{kind} :#{entry.name} " <>
            "on step :#{step.name} also runs. Each would record its own event, so one run " <>
            "would be logged twice. Give the handler its own update action."
        )
    end
  end

  defp error(context, message) do
    {:error,
     DslError.exception(
       module: context.module,
       path: context.path,
       message: message,
       location: Entity.anno(context.on_signal)
     )}
  end
end
