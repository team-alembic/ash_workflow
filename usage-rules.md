# Rules for working with AshWorkflow

## Understanding AshWorkflow

AshWorkflow is a declarative workflow orchestration extension for Ash Framework. It lets you define multi-step workflows — combining human actions, background jobs, and time-based deadlines — as a single DSL block. From your workflow declaration, it automatically generates:

- **State machine** states and transitions (via `ash_state_machine`)
- **Background job triggers** for automatic steps (via `ash_oban`)
- **Ash actions** for manual transitions, plus a read action
- **Timeout scheduling** for reminders and escalations

## Setting Up AshWorkflow

Add AshWorkflow to the extensions list on your Ash resource:

```elixir
use Ash.Resource,
  domain: MyApp.Domain,
  data_layer: AshPostgres.DataLayer,
  extensions: [AshWorkflow, AshOban]
```

AshWorkflow adds `AshStateMachine` for you. **You must add `AshOban` yourself**, as shown above, because the default scheduler generates AshOban triggers. Omitting it is a compile error naming the fix.

The reason it is not added for you: the scheduler is pluggable, and a workflow whose deadlines are run by something other than Oban should not carry the ash_oban DSL. See "Scheduling" below.

## Scheduling

Automatic steps and timeouts are run by a scheduler, chosen on the `workflow` block:

```elixir
workflow do
  scheduler AshWorkflow.Scheduler.Oban        # the default
  # or, with options:
  scheduler {AshWorkflow.Scheduler.Oban, check_interval: "0 * * * *"}
end
```

Set it once for an application instead:

```elixir
config :ash_workflow, scheduler: {AshWorkflow.Scheduler.Oban, queue: :workflow}
```

`AshWorkflow.Scheduler.Oban` polls: it turns each automatic step and each timeout into an AshOban trigger whose `where` clause finds eligible records. Polling is what puts a floor under accuracy — cron cannot ask for less than a minute, which is why a sub-minute `after` is rejected.

`AshWorkflow.Scheduler.Precise` arms a timer per deadline instead, so its floor is a millisecond and a sub-minute `after` compiles. Select it in the `workflow` block and start `AshWorkflow.Scheduler.Precise.Timeline` with the resources it recovers deadlines for:

```elixir
workflow do
  scheduler AshWorkflow.Scheduler.Precise
end

# in your supervision tree
{AshWorkflow.Scheduler.Precise.Timeline, resources: [MyApp.Order]}
```

A timer lives in memory, so it gives up Oban's durability: a deadline is recovered by the look-ahead sweep after a node dies, late by at most `:look_ahead_ms`. Across more than one node, pass `leader: {AshWorkflow.Scheduler.Leader.Oban, name: Oban}`, or every node arms the same timers. In tests call `AshWorkflow.Scheduler.Precise.run_due/2` rather than waiting for a timer, since the timeline holds no sandbox connection.

To write your own, implement `AshWorkflow.Scheduler`. It has one required callback:

```elixir
defmodule MyApp.Scheduler do
  use AshWorkflow.Scheduler

  @impl AshWorkflow.Scheduler
  def transform(dsl, works, opts) do
    # `works` is every AshWorkflow.Scheduler.Work this workflow declared.
    # Add whatever you need to the resource, or nothing.
    {:ok, dsl}
  end
end
```

Each `AshWorkflow.Scheduler.Work` describes one unit of scheduled work without reference to Oban. Two of its fields carry the same fact in different shapes, so opposite strategies both work:

- `match` — an Ash expression selecting records eligible **now**. All a polling scheduler needs.
- `deadline` — `%{field:, after:}`, the rule for computing the exact instant. All a scheduler that arms timers needs. `nil` for an automatic step, which is eligible as soon as a record occupies it.

Call `AshWorkflow.Scheduler.execute/3` when the moment arrives. It runs the action and routes failure to the step's `on_error`, so swapping schedulers changes when work happens and never what it does.

## Defining a Workflow

All workflow configuration goes inside a single `workflow do ... end` block. Steps are declared in order — the first non-terminal step becomes the initial state.

A step that declares no action, no transitions, no timeouts, no `on_success` and no `on_error` is terminal, whether or not it sets `terminal: true`. Setting it states the intent, and the verifier then rejects the step if it grows an outgoing declaration.

```elixir
workflow do
  step :process do
    action :run_processing
    on_success :review
    on_error :failed
  end

  step :review do
    transition :approve, to: :approved
    transition :reject, to: :rejected
  end

  step :approved, terminal: true
  step :rejected, terminal: true
  step :failed, terminal: true
end
```

## Step Types

There are exactly three kinds of steps:

### Automatic Steps

Run in the background via Oban when a record enters this state. You must define the referenced action as an update action on the resource.

```elixir
step :send_offer do
  action :send_offer_email
  on_success :awaiting_response
  on_error :send_failed
end
```

- `action` (required): References a user-defined update action on the resource.
- `on_success` (required): The step to transition to when the action succeeds. Repeatable — see below.
- `on_error` (optional): Step to transition to on failure. If omitted, the record stays in the current state on error.
- Must NOT have `transitions` or `terminal true`.

#### Conditional `on_success` routing

`on_success` is a repeatable entity, not a scalar option. Declare it more
than once, with a `when` condition, to fan an automatic step out to different
states based on what its action computed — reusing the same `route` entity
conditional transitions use:

```elixir
step :screening do
  action :run_screening
  on_success :interview,      when: expr(screen_score >= 5)
  on_success :rejected_by_hr, when: expr(screen_score < 5)
  on_error :screening_failed
end
```

The common single-target case still has an inline shorthand:

```elixir
step :send_offer, action: :send_offer_email, on_success: :awaiting_response, on_error: :send_failed
```

- Entries are evaluated in declaration order; the first matching one wins.
- An `on_success` with no `when` is unconditional — it always matches. At
  most one unconditional `on_success` is allowed per step, and if conditional
  entries are also present, the unconditional one must be declared **last**,
  as the fallback:

  ```elixir
  step :triaging do
    action :run_triage
    on_success :escalated, when: expr(priority == :high)
    on_success :queued                                    # fallback
  end
  ```

  Declaring an unconditional `on_success` before conditional ones is a
  compile-time error — it would shadow everything after it.
- **Timing**: `on_success` conditions are evaluated *after* the step's own
  action has run — including any attributes that action computed. This is
  the opposite of a manual transition's `route` conditions (see `route` under
  `transition`), which are evaluated against the record *before* the update
  they guard is applied, since there is no "after" for a transition that
  hasn't happened yet. The whole point of routing on `on_success` is to
  branch on what the action produced, so it has to run after.
- If every `on_success` is conditional and none matches at runtime, the
  update fails with an error naming the step and the record.
- Every `on_success` target must be a step declared elsewhere in the workflow.
- Conditions use SQL-style three-valued logic: comparing a `nil` attribute
  evaluates to `nil`, not `false`. A route whose condition evaluates to `nil`
  simply doesn't match, same as `false` — it falls through to the next route
  or the no-match error.
- A route may target its own step (a same-step retry loop) or any earlier
  step (a multi-step retry loop). Neither is rejected at compile time —
  reachability validation only checks whether a step is reachable from the
  initial step, not whether the path is acyclic.

### Manual Steps

Wait for a human (or external system) to trigger one of the declared transitions. Any step that declares one or more `transition` entries is a manual step — there is no separate `manual` flag. Each transition becomes a callable Ash update action.

```elixir
step :manager_review do
  transition :approve, to: :approved
  transition :reject, to: :rejected
  transition :request_changes, to: :drafting
end
```

- Must have at least one `transition`.
- Must NOT have `action`, `on_success`, or `on_error`.
- Transitions are called via the generated code interface: `MyResource.approve(record)`.

### Terminal Steps

End states with no outgoing transitions. Use the inline syntax:

```elixir
step :completed, terminal: true
step :failed, terminal: true
```

- Must NOT have `action`, `on_success`, `on_error`, `transitions`, or `timeouts`.

## Transitions

Each transition declared inside a manual step becomes an Ash update action. The same transition name can be used across multiple steps — they merge into a single action.

```elixir
# Same name, same target — merged into one action
step :review do
  transition :approve, to: :approved
  transition :reject, to: :rejected
end

step :escalated_review do
  transition :approve, to: :approved
  transition :reject, to: :rejected
end
```

```elixir
# Same name, different targets — auto-routes based on current state
step :initial_review do
  transition :complete, to: :detailed_review
end

step :detailed_review do
  transition :complete, to: :done
end
```

### Accepting Input on Transitions

If a transition needs to accept user input, define a matching update action:

```elixir
workflow do
  step :review do
    transition :reject, to: :rejected
  end
end

actions do
  update :reject do
    accept [:rejection_reason]
  end
end
```

AshWorkflow will inject its state-transition changes into the action you define. You only need to define actions that accept additional attributes — transitions with no extra input don't need a user-defined action.

## Timeouts

Timeouts fire when a workflow stays in a step longer than a specified duration. They are checked via Oban cron jobs.

### Action Timeout (stay in state, run side-effect)

```elixir
timeout :reminder, after: {3, :days}, action: :send_reminder
timeout :follow_up, after: {7, :days}, action: :send_follow_up, repeat: true
```

- `action`: References a user-defined update action. The workflow stays in the current state.
- `repeat: true`: Re-fires on the same interval. Useful for recurring reminders.

### Transition Timeout (force state change)

```elixir
timeout :escalation, after: {7, :days}, transition_to: :escalated
timeout :expire, after: {14, :days}, transition_to: :expired
```

- `transition_to`: Forces the workflow to move to the specified step.

### Workflow-Level Options

Set on the `workflow` block, applying to every generated trigger on the resource:

```elixir
workflow do
  state_attribute :status
  queue :fulfilment
  check_interval "0 * * * *"

  step :packing do
  end
end
```

- `state_attribute` (optional): the attribute the current step is stored in. Defaults to `:state`. AshWorkflow passes it down to `ash_state_machine`, so set it here rather than in a `state_machine` block. Everything generated follows it: the `match` expression on each unit of scheduled work, the `current_step`, `available_actions` and `pending_deadlines` calculations, and the recommended indexes. `state_entered_at` keeps its name either way.
- `queue` (optional): the Oban queue for all generated triggers. Defaults to `:workflow`. The queue MUST exist in your Oban config or Oban raises at boot.
- `check_interval` (optional): Oban cron expression controlling how often every trigger on the resource polls — automatic steps and timeouts alike. Defaults to `"* * * * *"` (every minute). Individual timeouts can override it.

Prefer raising `check_interval` over leaving the default when deadlines are measured in days. Every automatic step and every timeout gets its own scheduler, and each runs a query on every tick regardless of whether any record is waiting, so the cost scales with the number of triggers on the resource.

### Timeout Rules

- Each timeout must have EITHER `action` OR `transition_to` — not both, not neither.
- Supported duration units: `:seconds`, `:minutes`, `:hours`, `:days`.
- `check_interval` (optional): Oban cron expression for how often to poll. Defaults to the workflow-level `check_interval`, which itself defaults to `"* * * * *"` (every minute).

## Transition Log (Workflow History)

Declare an opt-in `transition_log` inside `workflow` to record one row per workflow event (transitions, automatic step completions, timeout firings) to a resource you own:

```elixir
workflow do
  transition_log MyApp.TicketTransition do
    belongs_to_actor :user, MyApp.Accounts.User
  end

  step :triage do
    transition :escalate, to: :urgent_queue
  end
end
```

- `transition_log` (arg `resource`, required): names the log resource module. Scaffold it with `mix ash_workflow.gen.transition_log MyApp.Ticket` — the log resource is user-owned, not generated by a transformer.
- `belongs_to_actor` (args `name`, `destination`, optional, nested inside `transition_log`): configures actor capture. Requires a matching `belongs_to` relationship on the log resource.

The log resource must define `from_state`, `to_state`, `transition_name`, `triggered_by` (all `:atom`), `occurred_at` (a datetime type), and a `belongs_to` back to the workflow resource — a compile-time verifier checks this.

When configured, the resource gains:

- `state_at/3` — the state a record was in at a given `DateTime`, resolved by walking the log.
- `history/2` — the full list of log rows for a record, ordered oldest first.
- `entered_current_state_at` — a calculation for when the state last *actually* changed, ignoring repeat rows (see below).

Both take an `effective: true` option, which omits rows a later undo reversed. See Undo below.

A repeating timeout writes a log row with `from_state == to_state` — it's not a state change, but it's a recorded event, and it's what lets the log reproduce `state_entered_at`'s value. This means `state_entered_at` (a timer anchor, reset by repeats) and `entered_current_state_at` (ignores repeats, the honest "entered this state" fact) can disagree. See [Workflow history](documentation/topics/workflow-history.md) for the full explanation and the documented aggregate-query recipe for "how many records were in state S at time Y".

This is not an audit trail (attribute-level changes) — pair it with AshPaperTrail for that — and not event sourcing; `state` stays a plain column.

## Undo

Undo rewinds a record to the state it occupied before its most recent state change. It requires a `transition_log`, and it is opt-in twice: an `undo` block on the workflow, plus `undoable?: true` on each transition that may be rewound.

```elixir
workflow do
  transition_log MyApp.TicketTransition do
    belongs_to_actor :user, MyApp.Accounts.User
  end

  undo do
    within {30, :minutes}
    same_actor? true
  end

  step :triage do
    transition :escalate, to: :urgent_queue, undoable?: true
    transition :close, to: :closed  # not undoable
  end
end
```

- `undoable?` (on `transition`, default `false`): whether this transition may be rewound. Nothing is undoable unless you say so.
- `within` (optional): how long after a transition it may still be undone, e.g. `{30, :minutes}`. Defaults to no limit.
- `same_actor?` (optional, default `false`): restrict undo to the actor recorded on the transition. Requires `belongs_to_actor` on the log.
- `policy` (optional): an `Ash.Policy.Check` tuple applied to the generated `undo` action. Step policies do not apply — an undo spans two states, and which step it rewinds into is only known at runtime.

An undo appends a row and never mutates or deletes one. The new row carries `triggered_by: :undo` and an `undoes_id` pointing at the row it reverses, so the log stays append-only and two readings of history stay derivable from the same rows:

- `history(record)` / `state_at(record, at)` — what actually happened, including states the record briefly occupied and rewound out of.
- `history(record, effective: true)` / `state_at(record, at, effective: true)` — what stands after corrections, with reversed rows omitted.

Prefer the literal reading for audit and for explaining side effects; prefer the effective reading for timeline UIs. Undoing an undo is a redo, and needs no special handling: it marks the undo row superseded in turn.

The resource gains a generated `undo` update action, plus `undoable?/2` (can this be undone) and `undo_target/2` (where it would land). Note that Ash's code interface separately generates `can_undo?/2`, which asks whether the *actor is authorized* to call `undo` — a different question.

Undo restores state, not attributes. A transition with `accept` does not have its accepted values rolled back, and side effects an action performed — an email sent, a payment taken — are not compensated. Mark a transition `undoable?: true` only when rewinding it is safe on its own.

Undo is refused, with a reason on `AshWorkflow.Errors.UndoNotPermitted`, when: the last state change was not an undoable transition (`:not_undoable` — this is what keeps automatic steps, timeouts and error paths out of reach), there is no state change to undo (`:no_history`), the `within` window has passed (`:window_expired`), or `same_actor?` does not match (`:different_actor` / `:no_actor`).

A transition whose target is an *automatic* step is undoable only until that step runs: once its Oban trigger fires, the head of the log is the automatic step's own row, and undo refuses with `:not_undoable`.

## Telemetry

Every state change emits a `[:ash_workflow, :transition]` span, and a conditional transition also emits `[:ash_workflow, :route_evaluation]`. `AshWorkflow.Changes.RecordEvent` emits the span, so one span covers a manual transition, an automatic step, a timeout, an error path, an undo and the initial create.

```elixir
:telemetry.attach("workflow-transitions", [:ash_workflow, :transition, :stop], &handle/4, nil)
```

Metadata carries `resource`, `workflow_id` (the primary key), `from_state`, `to_state`, `action`, `transition_name` and `triggered_by` (`:initial`, `:manual`, `:automatic`, `:timeout`, `:error_path`, `:undo`) — the same vocabulary the transition log records.

Two things to know when reading the events. A create's start event carries no `workflow_id`, because the record does not exist yet; its stop event carries it. A conditional transition's start event carries no `to_state`, because the route is chosen at runtime; its stop event carries the state the record landed in.

Nothing stores these. Use the transition log for durable history, and telemetry for a live stream. See `AshWorkflow.Telemetry`.

## Authorization

### Step-Level Policies

Apply a policy check to all transitions in a manual step:

```elixir
step :manager_review do
  policy actor_attribute_equals(:role, :manager)

  transition :approve, to: :approved
  transition :reject, to: :rejected
end
```

Available built-in checks (imported automatically):
- `actor_attribute_equals(attribute, value)`
- `relates_to_actor_via(relationship_path)`
- `actor_present()`

### Resource-Level Policies

For more complex authorization, use standard Ash policies targeting the generated action names:

```elixir
policies do
  policy action(:approve) do
    authorize_if actor_attribute_equals(:role, :manager)
  end

  policy action(:offer) do
    authorize_if relates_to_actor_via(:assigned_recruiter)
  end
end
```

Resource-level policies take precedence — if you define a policy targeting a specific transition action, the step-level policy is not applied for that action.

## Generated Artifacts

AshWorkflow generates these automatically — do NOT define them yourself:

| Artifact | Details |
|---|---|
| `:state` attribute | Added by `ash_state_machine`. Rename it with `state_attribute` |
| `:state_entered_at` attribute | `utc_datetime_usec`, tracks when current state was entered |
| Primary `:read` action | Added if automatic steps exist (needed for Oban triggers) |
| Transition update actions | One per manual transition |
| Timeout transition actions | Hidden `__timeout_<step>_<name>` actions |
| Oban triggers | Schedulers and workers for automatic steps and timeouts |
| State machine DSL | States, transitions, initial state |

## What You Must Define

- **Attributes**: Your resource's domain attributes (id, name, etc.)
- **Update actions for automatic steps**: The action referenced by `action :my_action` must be defined as an update action.
- **Update actions for transitions that accept input**: Only needed if the transition takes additional parameters.
- **Update actions for action timeouts**: The action referenced by `timeout :name, action: :my_action` must be defined.
- **Domain**: The resource must belong to an Ash domain.
- **Data layer**: Typically `AshPostgres.DataLayer`.

## Common Patterns

### Loopback / Revision Cycles

Steps can transition back to earlier steps:

```elixir
step :draft do
  transition :submit, to: :review
end

step :review do
  transition :approve, to: :approved
  transition :request_changes, to: :draft  # loops back
end
```

### Mixed Automatic and Manual Pipelines

Chain automatic processing with human decision points:

```elixir
workflow do
  step :intake do
    action :process_intake
    on_success :triage
    on_error :intake_failed
  end

  step :triage do
    transition :assign, to: :processing
    transition :reject, to: :rejected
  end

  step :processing do
    action :run_processing
    on_success :review
    on_error :processing_failed
  end

  step :review do
    transition :complete, to: :completed
    transition :retry, to: :processing  # send back for reprocessing
  end

  step :completed, terminal: true
  step :rejected, terminal: true
  step :intake_failed, terminal: true
  step :processing_failed, terminal: true
end
```

### Escalation with Timeout

```elixir
step :awaiting_approval do
  transition :approve, to: :approved

  timeout :reminder, after: {2, :days}, action: :send_approval_reminder
  timeout :escalate, after: {5, :days}, transition_to: :escalated
end
```

## Compile-Time Validation

AshWorkflow validates your workflow at compile time and raises clear errors for:

- Missing steps (no non-terminal steps defined)
- Invalid step configuration (e.g., a step with both `action` and `transitions`, or with neither)
- Timeouts with both `action` and `transition_to` (or neither)
- References to undefined steps (in `on_success`, `on_error`, `transition :to`, `timeout :transition_to`)
- An automatic step declaring no `on_success`
- More than one unconditional `on_success` on a step, or an unconditional `on_success` declared before a conditional one (it would shadow it)
- Unreachable steps (not connected to the first step via any path)

## Important Caveats

- **Do not add `AshStateMachine` or `AshOban` to your extensions list** — AshWorkflow injects their DSL automatically. Adding them manually will cause conflicts.
- **Shared transition names merge** — same-named transitions across steps become one action that routes based on current state.
- **The first non-terminal step is the initial state** — order matters for the first step.
- **Automatic steps use Oban** — ensure your application has Oban configured and running.
- **`state_entered_at` is managed automatically** — do not set it manually in your actions.
