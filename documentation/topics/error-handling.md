# Error Handling

AshWorkflow handles errors through the `on_error` option on automatic steps, and relies on AshStateMachine to reject transitions the workflow never declared. This guide covers what happens when a step fails and how to design workflows around failure.

## Automatic step failures

When an automatic step's action fails — it raises, or a change adds a changeset error — Ash rolls the action back. The `on_success` transition never happens, so the record is still in the step when the job ends.

What happens next depends on whether the step declares `on_error`.

### With `on_error`

`AshWorkflow.Transformers.AddActions` generates a hidden update action named `__on_error_<step>` and `AshWorkflow.Transformers.AddScheduler` wires it to the generated trigger's `on_error`. That action transitions the record to the error state and records the event.

```elixir
workflow do
  step :process, action: :do_processing, on_success: :done, on_error: :failed
  step :done, terminal: true
  step :failed, terminal: true
end
```

When `:do_processing` fails:

1. Oban records the failed attempt. AshWorkflow does not set `max_attempts` on the triggers it generates, so AshOban's default of `1` applies and the first failure is also the last attempt.
2. AshOban calls `__on_error_process`, which transitions the record from `:process` to `:failed`.
3. `AshWorkflow.Changes.RecordEvent` writes a transition log row for that transition with `triggered_by: :error_path`, and `AshWorkflow.Telemetry` emits the state change.
4. Oban marks the job completed rather than discarded, because AshOban's `on_error_fails_job?` defaults to `false`.

The record does not stay in `:process` waiting for an operator. It moves to `:failed`, and the trigger's filter stops matching it. Read the failure back off the transition log rather than off the job table.

### Without `on_error`

A step with no `on_error` has no error action for the trigger to call. The job fails, the record stays in the step, and the trigger matches it again on the next scheduler cycle. The action runs again, and keeps running on every cycle until it succeeds or someone moves the record by hand. Declare `on_error` on every automatic step whose action can fail.

## Designing for failure

### Make step actions idempotent

A step's action can run more than once: on a repeat cycle when the step has no `on_error`, and on a retry if you raise `max_attempts` on the generated trigger. Actions should be safe to run twice. If a step sends an email, record a flag on the record and check it, rather than sending again.

### Use error states for investigation

Rather than making an error state terminal, make it a manual step with a transition back into the workflow:

```elixir
workflow do
  step :process, action: :do_processing, on_success: :done, on_error: :needs_review

  step :needs_review do
    transition :retry, to: :process
    transition :abandon, to: :abandoned
  end

  step :done, terminal: true
  step :abandoned, terminal: true
end
```

A record that fails `:do_processing` lands in `:needs_review` on the first failure, with an `:error_path` row naming the transition. An operator lists records in that state, reads the row, and either retries or abandons.

## Manual transition failures

Manual transitions fail if the state machine rejects them — for example, calling `:approve` on a record that's already in `:approved`. The error includes a `NoMatchingTransition` message with the current state and attempted target.

## Conditional route failures

If a conditional transition has no matching route for the current record, the action fails with a descriptive error. If a route's `when` expression fails to evaluate (e.g., references a missing field), the error includes the specific expression that failed and the underlying reason.

## Compensation and rollback

AshWorkflow does not provide automatic compensation or rollback. Each transition is an Ash action, and Ash handles transactional semantics at the action level — if a change within an action fails, the entire action is rolled back.

If your workflow creates side effects (external API calls, related records) that need cleanup on failure, handle this in your action's error paths or in a dedicated error-handling step.
