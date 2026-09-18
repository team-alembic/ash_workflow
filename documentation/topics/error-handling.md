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

1. Oban records the failed attempt. `max_attempts` comes from the step's `retry` block and defaults to `1`, so without one the first failure is also the last attempt.
2. Once the last attempt has failed, AshOban calls `__on_error_process`, which transitions the record from `:process` to `:failed`.
3. `AshWorkflow.Changes.RecordEvent` writes a transition log row for that transition with `triggered_by: :error_path`, and `AshWorkflow.Telemetry` emits the state change.
4. Oban marks the job completed rather than discarded, because AshOban's `on_error_fails_job?` defaults to `false`.

The record does not stay in `:process` waiting for an operator. It moves to `:failed`, and the trigger's filter stops matching it. Read the failure back off the transition log rather than off the job table.

### Without `on_error`

A step with no `on_error` has no error action for the trigger to call. The job fails, the record stays in the step, and the trigger matches it again on the next scheduler cycle. The action runs again, and keeps running on every cycle until it succeeds or someone moves the record by hand. Declare `on_error` on every automatic step whose action can fail.

## Retry

A step or a timeout can declare a `retry` block, the failure policy for its generated work:

```elixir
step :process do
  action :do_processing
  on_success :done
  on_error :failed

  retry do
    max_attempts 3
    backoff {10, :seconds}
  end
end
```

- `max_attempts` defaults to `1`. A step with no `retry` block gets that default, so its `on_error` moves it to the error state on the very first failure. The example above raises that to three attempts before `:process` moves to `:failed`.
- `backoff` is a duration tuple, such as `{10, :seconds}`, for a fixed delay between attempts, or `:exponential` to grow the delay with the attempt number. It has no effect while `max_attempts` is `1`.

A timeout can declare its own `retry` block, with the same options and the same defaults:

```elixir
timeout :reminder do
  fire_after {3, :days}
  action :send_reminder

  retry do
    max_attempts 3
  end
end
```

`AshWorkflow.Scheduler.Oban` and `AshWorkflow.Scheduler.Precise` honour `retry` through different mechanisms but the same meaning. Oban turns `max_attempts` and `backoff` into the generated trigger's own options and lets Oban's own retry loop run the attempts. Precise re-arms its timer for the backoff delay after a failed attempt, under the same key the original deadline used. Either way, `on_error` runs only after the final attempt has failed. It never runs on an attempt a retry will follow.

A `retry` block is rejected at compile time on a manual step, a wait state, or a terminal step, since none of them has a generated trigger for it to apply to.

## Designing for failure

### Make step actions idempotent

A step's action can run more than once: on a repeat cycle when the step has no `on_error`, and on every attempt the step's `retry` block allows. Actions should be safe to run twice. If a step sends an email, record a flag on the record and check it, rather than sending again.

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

An automatic step's `on_success` fails the same way when none of its conditions match: the action succeeded, but `AshWorkflow.Changes.ConditionalOnSuccess` finds no route to take, so it adds `AshWorkflow.Errors.NoMatchingRoute` — naming the step and the action — to the changeset. That failure runs down the step's `on_error` exactly like any other, described above. `AshWorkflow.Verifiers.ValidateWorkflow` requires `on_error` on any step whose `on_success` is not statically exhaustive (no trailing unconditional entry), so this path always exists for a step that compiles.

## Compensation and rollback

AshWorkflow does not provide automatic compensation or rollback. Each transition is an Ash action, and Ash handles transactional semantics at the action level — if a change within an action fails, the entire action is rolled back.

If your workflow creates side effects (external API calls, related records) that need cleanup on failure, handle this in your action's error paths or in a dedicated error-handling step.
