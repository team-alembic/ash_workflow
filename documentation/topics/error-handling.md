# Error Handling

AshWorkflow provides error handling through the `on_error` option on automatic steps and relies on AshStateMachine for transition safety. This guide covers how errors behave and how to design workflows that handle failures gracefully.

## Automatic step failures

When an automatic step's action fails (raises an error or adds a changeset error), the state does **not** change. The record stays in its current step.

If you've configured `on_error`, the state machine permits a transition to the error state — but AshWorkflow does not automatically perform this transition on failure. The transition to the error state happens through Oban's error handling or your own custom logic.

```elixir
workflow do
  step :process, action: :do_processing, on_success: :done, on_error: :failed
  step :done, terminal: true
  step :failed, terminal: true
end
```

In this example, if `:do_processing` fails:
1. The Oban job fails and may retry (depending on `max_attempts` configuration)
2. If all retries are exhausted, the record remains in `:process`
3. The `on_error` configuration tells the state machine that a transition from `:process` to `:failed` via the `:do_processing` action is valid

## Designing for failure

### Make step actions idempotent

Because Oban may retry failed jobs, your step actions should be safe to run multiple times. If a step sends an email, use a flag to track whether it was already sent rather than re-sending on retry.

### Use error states for investigation

Rather than making error states terminal, consider making them manual steps with a transition back to the previous step:

```elixir
workflow do
  step :process, action: :do_processing, on_success: :done, on_error: :needs_review

  step :needs_review do
    manual true
    transition :retry, to: :process
    transition :abandon, to: :abandoned
  end

  step :done, terminal: true
  step :abandoned, terminal: true
end
```

This lets operators investigate failures and either retry or abandon the workflow.

## Manual transition failures

Manual transitions fail if the state machine rejects them — for example, calling `:approve` on a record that's already in `:approved`. The error includes a `NoMatchingTransition` message with the current state and attempted target.

## Conditional route failures

If a conditional transition has no matching route for the current record, the action fails with a descriptive error. If a route's `when` expression fails to evaluate (e.g., references a missing field), the error includes the specific expression that failed and the underlying reason.

## Compensation and rollback

AshWorkflow does not provide automatic compensation or rollback. Each transition is an Ash action, and Ash handles transactional semantics at the action level — if a change within an action fails, the entire action is rolled back.

If your workflow creates side effects (external API calls, related records) that need cleanup on failure, handle this in your action's error paths or in a dedicated error-handling step.
