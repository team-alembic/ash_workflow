# Automatic vs Manual Steps

AshWorkflow steps come in four flavours: automatic, manual, wait states, and terminal.

You never declare which kind a step is. The kind is inferred from its shape:

| The step declares | It is |
|---|---|
| an `action` | automatic |
| one or more `transition` entries | manual |
| neither, plus a `timeout` with `transition_to` | a wait state |
| nothing at all | terminal |

## Automatic steps

Automatic steps run background work via Oban as soon as the workflow enters that state. You define them with an `action` (referencing a user-defined update action) and `on_success` (the next state):

```elixir
step :process_application do
  action :process_application
  on_success :review
  on_error :processing_failed
end
```

### How it works

1. The extension generates an Oban trigger with `where: expr(state == :process_application)`
2. When the scheduler fires, it finds records in that state and runs `:process_application`
3. The extension has injected `transition_state(:review)` into your action, so on success the state advances
4. If the action raises or returns an error, and `on_error` is set, the state moves there instead

### Fanning out with multiple `on_success` entries

`on_success` is a repeatable entity, not a scalar option — declaring it more
than once, with a `when` condition, fans a record out to different states
based on what the step's action computed. When an automatic step's outcome is
itself a business decision — an AI screening step that either advances a
candidate or rejects them, say — modelling the rejection as `on_error` is
wrong: it wasn't a failure, it was an outcome, and `on_error` fires from
*actual* failures (exceptions, validation errors). Declare more than one
`on_success` instead, each with a `when`:

```elixir
step :screening do
  action :run_screening
  on_success :interview,      when: expr(screen_score >= 5)
  on_success :rejected_by_hr, when: expr(screen_score < 5)
  on_error :screening_failed
end
```

Entries are evaluated in declaration order, first match wins. An `on_success`
with no `when` is unconditional — it always matches, so at most one is
allowed per step, and if conditional entries are also present the
unconditional one must be declared last, as the fallback:

```elixir
step :triaging do
  action :run_triage
  on_success :escalated, when: expr(priority == :high)
  on_success :queued                                    # fallback — no `when`
end
```

Declaring an unconditional `on_success` before conditional ones is a
compile-time error: it would always match first and shadow everything after
it. If every `on_success` on a step is conditional and none matches at
runtime, the update fails with an error naming the step and the record —
there is no silent "stay put".

Conditions follow SQL's three-valued logic, not Elixir's: comparing a `nil`
attribute (one the action never set) evaluates to `nil`, not `false`. A route
with a `nil` condition simply doesn't match — it falls through to the next
route, or to the no-match error if there isn't one — the same as an
explicitly `false` condition would. There's no separate "unknown" outcome to
handle.

An `on_success` route can target the step it's declared on, or any earlier
step — both are legitimate retry patterns, not mistakes, and neither is
rejected at compile time. Reachability validation only asks whether a step
can be reached from the workflow's initial step, not whether the path to it
is acyclic:

```elixir
step :attempting do
  action :run_attempt
  on_success :attempting, when: expr(attempts < 3)  # retry, same step
  on_success :succeeded,  when: expr(attempts >= 3)
end
```

The inline shorthand still works for the common single-target case:

```elixir
step :process_application, action: :process_application, on_success: :review, on_error: :processing_failed
```

**Timing matters here, and it's the opposite of manual `route`s.** A manual
transition's `route` conditions run against the record *before* the update
they guard — there's no "after" for something that hasn't happened yet.
`on_success` conditions run *after* the step's own action, against whatever
that action computed (`screen_score`, in the example above). That's
deliberate: the entire reason to route on `on_success` is to branch on what
the action produced, which doesn't exist until the action has run.

### User-defined actions

You must define the update action yourself with your business logic. The extension appends `transition_state` and `state_entered_at` changes to it:

```elixir
actions do
  update :process_application do
    accept []
    change MyApp.Changes.ParseResume
    change MyApp.Changes.CheckDuplicates
  end
end
```

If the action doesn't exist on the resource, compilation fails with a clear error.

## Wait states

A wait state runs nothing on entry and offers no transition anybody can call. Records sit in it until a timeout moves them on, which makes it the step to reach for when the only thing you are waiting on is the clock:

```elixir
step :cooling_off do
  timeout :period_elapsed,
    after: {14, :days},
    transition_to: :active
end
```

Because a timeout is the only exit, a wait state must declare at least one timeout with `transition_to`. One with only an action-style timeout would trap records forever, so the extension rejects it at compile time. `on_success` and `on_error` are also rejected: with no action to succeed or fail, neither could ever fire.

A wait state's deadline can come from the record rather than the clock, using `field`. That is how you give each record its own delay:

```elixir
step :scheduled do
  timeout :due,
    after: {1, :minutes},
    field: :run_at,
    transition_to: :running
end
```

See `d:AshWorkflow.workflow.step.timeout` and [Timeouts and Deadlines](timeouts-and-deadlines.md) for the full timeout surface.

## Manual steps

Manual steps wait for a human (or external system) to call a transition action. Any step that declares one or more named `transition` entries is treated as manual:

```elixir
step :review do
  transition :approve, to: :next_step
  transition :reject, to: :rejected
end
```

A step with transitions must not also declare an `action`, `on_success`, or `on_error` — those belong to automatic steps.

### Generated actions

Each transition becomes an Ash update action with `transition_state` baked in. The extension also generates code interface functions:

```elixir
# These are generated and callable:
MyResource.approve(record)
MyResource.reject(record)

# Or via Ash directly:
Ash.update(record, action: :approve)
```

### Accepting inputs on transitions

By default, generated transition actions don't accept any inputs. Use `accept` to allow callers to pass data when triggering a transition:

```elixir
step :review do
  transition :approve, to: :approved
  transition :reject, to: :rejected, accept: [:reason]
end
```

The generated `:reject` action will accept the `:reason` attribute:

```elixir
MyResource.reject(record, %{reason: "Not qualified"})
```

If you need more control (custom changes, validations), define the action yourself — the extension merges its changes into your action.

### Shared transition names

The same transition name can be used across multiple steps. They merge into a single Ash action. If the targets are the same, the state machine handles routing via `from:` lists. If the targets differ, the action automatically routes based on the current state at runtime:

```elixir
# Same name, same target — one action, state machine enforces valid from: states
step :screening do
  transition :reject, to: :rejected
end

step :interview do
  transition :reject, to: :rejected
end

# Same name, different targets — one action, routes based on current state
step :initial_review do
  transition :complete, to: :detailed_review
end

step :detailed_review do
  transition :complete, to: :done
end
```

### Conditional transitions

A transition can route to different states based on record attributes using conditional routes. The workflow evaluates conditions at runtime and picks the first match:

```elixir
step :review do
  transition :complete_review do
    route :fast_track, when: expr(priority == :urgent)
    route :standard_processing, when: expr(priority == :normal)
  end

  transition :reject_review, to: :rejected
end
```

The user calls `:complete_review` — the workflow checks `priority` and routes accordingly. If no condition matches, the action fails with a clear error.

Conditions use `expr()` — the same Ash expression syntax used in filters and policies. They have access to all record attributes.

## Terminal steps

Terminal steps are end states. A step that declares no action, no transitions, no timeouts, no `on_success` and no `on_error` has no way out, so `AshWorkflow.Entities.Step.terminal?/1` reports it as terminal whether or not it says so:

```elixir
step :approved
step :rejected
```

`terminal: true` states the intent, and `AshWorkflow.Verifiers.ValidateWorkflow` then rejects the step if it grows an outgoing declaration:

```elixir
step :approved, terminal: true
```

Either way, a step nothing transitions to is rejected as unreachable, so a name typo'd in one place and not the other does not become a silent end state.

## Initial state

By default, the first non-terminal step in declaration order becomes the initial state. You can override this with `initial true`:

```elixir
workflow do
  step :intake, action: :run_intake, on_success: :review

  step :review do
    initial true   # ← this is the initial state, despite being declared second
    transition :approve, to: :done
  end

  step :done, terminal: true
end
```

At most one step can have `initial true`. If none do, the first non-terminal step is used.

The extension sets `default_initial_state` and `initial_states` on the generated state machine.
