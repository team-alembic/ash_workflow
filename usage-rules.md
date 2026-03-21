# Rules for working with AshWorkflow

## Understanding AshWorkflow

AshWorkflow is a declarative workflow orchestration extension for Ash Framework. It lets you define multi-step workflows — combining human actions, background jobs, and time-based deadlines — as a single DSL block. From your workflow declaration, it automatically generates:

- **State machine** states and transitions (via `ash_state_machine`)
- **Background job triggers** for automatic steps (via `ash_oban`)
- **Ash actions** for manual transitions and the `:start` create action
- **Timeout scheduling** for reminders and escalations

## Setting Up AshWorkflow

Add AshWorkflow to the extensions list on your Ash resource:

```elixir
use Ash.Resource,
  domain: MyApp.Domain,
  data_layer: AshPostgres.DataLayer,
  extensions: [AshWorkflow]
```

AshWorkflow requires `ash_state_machine` and `ash_oban` as dependencies. You do NOT need to add `AshStateMachine` or `AshOban` to the extensions list — AshWorkflow generates and injects the necessary DSL for both automatically.

## Defining a Workflow

All workflow configuration goes inside a single `workflow do ... end` block. Steps are declared in order — the first non-terminal step becomes the initial state.

```elixir
workflow do
  step :process do
    action :run_processing
    on_success :review
    on_error :failed
  end

  step :review do
    manual true
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
- `on_success` (required): Step to transition to when the action succeeds.
- `on_error` (optional): Step to transition to on failure. If omitted, the record stays in the current state on error.
- Must NOT have `manual true`, `transitions`, or `terminal true`.

### Manual Steps

Wait for a human (or external system) to trigger one of the declared transitions. Each transition becomes a callable Ash update action.

```elixir
step :manager_review do
  manual true

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
  manual true
  transition :approve, to: :approved
  transition :reject, to: :rejected
end

step :escalated_review do
  manual true
  transition :approve, to: :approved
  transition :reject, to: :rejected
end
```

```elixir
# Same name, different targets — auto-routes based on current state
step :initial_review do
  manual true
  transition :complete, to: :detailed_review
end

step :detailed_review do
  manual true
  transition :complete, to: :done
end
```

### Accepting Input on Transitions

If a transition needs to accept user input, define a matching update action:

```elixir
workflow do
  step :review do
    manual true
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

### Timeout Rules

- Each timeout must have EITHER `action` OR `transition_to` — not both, not neither.
- Supported duration units: `:seconds`, `:minutes`, `:hours`, `:days`.
- `check_interval` (optional): Oban cron expression for how often to poll. Defaults to `"* * * * *"` (every minute).

## Authorization

### Step-Level Policies

Apply a policy check to all transitions in a manual step:

```elixir
step :manager_review do
  manual true
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
| `:state` attribute | Added by `ash_state_machine` |
| `:state_entered_at` attribute | `utc_datetime_usec`, tracks when current state was entered |
| `:start` create action | Sets initial state and `state_entered_at` |
| Primary `:read` action | Added if automatic steps exist (needed for Oban triggers) |
| Transition update actions | One per manual transition |
| Timeout transition actions | Hidden `__timeout_<name>` actions |
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
  manual true
  transition :submit, to: :review
end

step :review do
  manual true
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
    manual true
    transition :assign, to: :processing
    transition :reject, to: :rejected
  end

  step :processing do
    action :run_processing
    on_success :review
    on_error :processing_failed
  end

  step :review do
    manual true
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
  manual true
  transition :approve, to: :approved

  timeout :reminder, after: {2, :days}, action: :send_approval_reminder
  timeout :escalate, after: {5, :days}, transition_to: :escalated
end
```

## Compile-Time Validation

AshWorkflow validates your workflow at compile time and raises clear errors for:

- Missing steps (no non-terminal steps defined)
- Invalid step configuration (e.g., manual step with `action`, automatic step with `transitions`)
- Timeouts with both `action` and `transition_to` (or neither)
- References to undefined steps (in `on_success`, `on_error`, `transition :to`, `timeout :transition_to`)
- Unreachable steps (not connected to the first step via any path)

## Important Caveats

- **Do not add `AshStateMachine` or `AshOban` to your extensions list** — AshWorkflow injects their DSL automatically. Adding them manually will cause conflicts.
- **Shared transition names merge** — same-named transitions across steps become one action that routes based on current state.
- **The first non-terminal step is the initial state** — order matters for the first step.
- **Automatic steps use Oban** — ensure your application has Oban configured and running.
- **`state_entered_at` is managed automatically** — do not set it manually in your actions.
