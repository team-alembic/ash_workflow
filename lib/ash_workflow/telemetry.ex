defmodule AshWorkflow.Telemetry do
  @moduledoc """
  Telemetry events emitted by AshWorkflow.

  AshWorkflow emits the following `:telemetry` events to provide observability
  into workflow progression. Events are always emitted but are zero-cost when
  no handlers are attached.

  ## Transition Events

  `[:ash_workflow, :transition]` is a span emitted around every state transition,
  regardless of how it was triggered (manual, automatic, or timeout).

  * `[:ash_workflow, :transition, :start]` — emitted when a transition begins
    * Measurements: `%{system_time: integer()}`
    * Metadata: `%{resource: module(), workflow_id: term(), from_state: atom() | nil, to_state: atom(), action: atom(), transition_name: atom(), trigger: :manual | :automatic | :timeout}`

  * `[:ash_workflow, :transition, :stop]` — emitted when a transition completes
    * Measurements: `%{system_time: integer(), duration: integer()}`
    * Metadata: same as `:start`

  ## Route Evaluation Events

  `[:ash_workflow, :route_evaluation]` is emitted when a conditional transition
  evaluates its routes to determine the target state.

  * Measurements: `%{system_time: integer()}`
  * Metadata: `%{resource: module(), transition_name: atom(), from_state: atom(), matched_route: atom() | nil, routes_evaluated: integer()}`

  ## Integrating with OpenTelemetry

  Use the `opentelemetry_telemetry` library to bridge these events into
  OpenTelemetry spans:

      :otel_telemetry.attach(
        "ash-workflow",
        [:ash_workflow, :transition]
      )

  Alternatively, attach custom handlers:

      :telemetry.attach(
        "my-handler",
        [:ash_workflow, :transition, :start],
        &MyApp.handle_event/4,
        nil
      )

  ## Correlating Events

  All transition events include `workflow_id` (the resource's primary key value),
  which serves as the natural correlation key for reconstructing workflow timelines
  across multiple events.
  """

  @transition_start [:ash_workflow, :transition, :start]
  @transition_stop [:ash_workflow, :transition, :stop]
  @route_evaluation [:ash_workflow, :route_evaluation]

  @doc false
  def emit_transition_start(metadata) do
    :telemetry.execute(@transition_start, %{system_time: System.system_time()}, metadata)
  end

  @doc false
  def emit_transition_stop(metadata, duration) do
    :telemetry.execute(
      @transition_stop,
      %{system_time: System.system_time(), duration: duration},
      metadata
    )
  end

  @doc false
  def emit_route_evaluation(metadata) do
    :telemetry.execute(@route_evaluation, %{system_time: System.system_time()}, metadata)
  end
end
