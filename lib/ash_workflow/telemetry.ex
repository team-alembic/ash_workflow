defmodule AshWorkflow.Telemetry do
  @moduledoc """
  The `:telemetry` events AshWorkflow emits.

  Every event is emitted unconditionally and costs a function call with no
  handlers attached, which is the same arrangement Ecto, Oban and Phoenix use.
  `:telemetry` is already in the dependency tree through Ash and Oban, so this
  adds no dependency.

  ## Transition events

  `[:ash_workflow, :transition]` is a span around every state change, whoever
  caused it. `AshWorkflow.Changes.RecordEvent` emits it, and that change runs on
  every action AshWorkflow generates, so a manual transition, an automatic step,
  a timeout, an error path, an undo and the initial create all produce one.

  `[:ash_workflow, :transition, :start]` measures `%{system_time: integer()}`,
  and `[:ash_workflow, :transition, :stop]` adds `duration`. Both carry:

      %{
        resource: module(),
        workflow_id: term(),
        from_state: atom() | nil,
        to_state: atom() | nil,
        action: atom(),
        transition_name: atom(),
        triggered_by: triggered_by()
      }

  On `:stop`, `to_state` is read from the record the action returned. On
  `:start` it is the declared target, which is `nil` for a conditional
  transition whose target is only known at runtime.

  `duration` is in `:native` units, measured with `System.monotonic_time/0`.

  ## Route evaluation

  `[:ash_workflow, :route_evaluation]` fires when
  `AshWorkflow.Changes.ConditionalTransition` picks between routes, which is
  where a transition declared on more than one step, or with explicit `route`
  entities, decides where it lands.

  It measures `%{system_time: integer()}` and carries:

      %{
        resource: module(),
        transition_name: atom(),
        from_state: atom() | nil,
        matched_route: atom() | nil,
        routes_evaluated: pos_integer()
      }

  `matched_route` is `nil` when no route matched, which is the case that fails
  the action.

  ## Reading `triggered_by`

  The same vocabulary the transition log records, so a span and a log row
  describe an event the same way:

  * `:initial` — the record was created
  * `:manual` — someone called a transition action
  * `:automatic` — an automatic step ran
  * `:timeout` — a deadline fired
  * `:error_path` — a step failed and its `on_error` ran
  * `:undo` — a transition was rewound

  ## Attaching a handler

      :telemetry.attach(
        "workflow-transitions",
        [:ash_workflow, :transition, :stop],
        &MyApp.Telemetry.handle_event/4,
        nil
      )

  ## Bridging to OpenTelemetry

  `opentelemetry_telemetry` turns the span into an OpenTelemetry span:

      :otel_telemetry.attach("ash-workflow", [:ash_workflow, :transition])

  `workflow_id` is the record's primary key, so it is the key to correlate every
  event for one workflow instance.
  """

  @type triggered_by :: :initial | :manual | :automatic | :timeout | :error_path | :undo

  @transition_start [:ash_workflow, :transition, :start]
  @transition_stop [:ash_workflow, :transition, :stop]
  @route_evaluation [:ash_workflow, :route_evaluation]

  @doc false
  @spec transition_start(map()) :: integer()
  def transition_start(metadata) do
    :telemetry.execute(@transition_start, %{system_time: System.system_time()}, metadata)

    System.monotonic_time()
  end

  @doc false
  @spec transition_stop(map(), integer()) :: :ok
  def transition_stop(metadata, started_at) do
    :telemetry.execute(
      @transition_stop,
      %{system_time: System.system_time(), duration: System.monotonic_time() - started_at},
      metadata
    )
  end

  @doc false
  @spec route_evaluation(map()) :: :ok
  def route_evaluation(metadata) do
    :telemetry.execute(@route_evaluation, %{system_time: System.system_time()}, metadata)
  end
end
