# Telemetry

AshWorkflow emits `:telemetry` events around every state change and every conditional route evaluation. `:telemetry` is already in the dependency tree through Ash and Oban, so nothing is added to `mix.exs`, and an event with no handlers attached costs one function call.

`AshWorkflow.Telemetry` is the reference for the event names and their metadata. This page is about what to do with them.

## The events

| Event | When |
| --- | --- |
| `[:ash_workflow, :transition, :start]` | A state-changing action begins |
| `[:ash_workflow, :transition, :stop]` | It finishes, with `duration` |
| `[:ash_workflow, :route_evaluation]` | A conditional transition picks a route |

`AshWorkflow.Changes.RecordEvent` emits the span, and that change runs on every action AshWorkflow generates. So a manual transition, an automatic step, a timeout, an error path, an undo and the initial create all produce one span, and `triggered_by` says which:

```elixir
:telemetry.attach(
  "workflow-transitions",
  [:ash_workflow, :transition, :stop],
  fn _event, %{duration: duration}, metadata, _config ->
    ms = System.convert_time_unit(duration, :native, :millisecond)

    Logger.info(
      "#{inspect(metadata.resource)} #{inspect(metadata.workflow_id)} " <>
        "#{metadata.from_state} -> #{metadata.to_state} " <>
        "(#{metadata.triggered_by}, #{ms}ms)"
    )
  end,
  nil
)
```

## Correlating events

`workflow_id` is the record's primary key, so it is the key that ties every event for one workflow instance together. It is `nil` on the `:start` of a create, because the record does not exist yet; the matching `:stop` carries it.

## `to_state` is not known up front for a conditional transition

A transition declared on more than one step, or with explicit `route` entities, chooses its target at runtime in `AshWorkflow.Changes.ConditionalTransition`. Its `:start` therefore carries `to_state: nil`, and the `:stop` carries the state the record landed in. `[:ash_workflow, :route_evaluation]` reports which route matched and how many were considered, and it fires whether or not one matched — a transition that matched nothing is the case worth alerting on, since it fails the action.

## OpenTelemetry

`opentelemetry_telemetry` turns the span into an OpenTelemetry span:

```elixir
:otel_telemetry.attach("ash-workflow", [:ash_workflow, :transition])
```

## Telemetry and the transition log are different tools

Both describe the same events, and `triggered_by` deliberately uses the same vocabulary in both, but they answer different questions.

The transition log is durable, queryable history that belongs to the record. It survives restarts, it is what `AshWorkflow.TransitionLog.history/2` and `AshWorkflow.TransitionLog.state_at/3` read, and it is what an undo points at. See [Workflow history](workflow-history.md).

Telemetry is a live stream with no storage. It is what a dashboard, an APM trace or an alert reads, and nothing retains it unless a handler does. It also covers workflows that configure no transition log at all.

Use the log to answer "what happened to this record". Use telemetry to answer "what is happening across all of them, right now".
