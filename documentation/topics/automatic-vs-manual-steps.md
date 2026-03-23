# Automatic vs Manual Steps

AshWorkflow steps come in three flavours: automatic, manual, and terminal.

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

## Manual steps

Manual steps wait for a human (or external system) to call a transition action. Define them with `manual true` and one or more named transitions:

```elixir
step :review do
  manual true

  transition :approve, to: :next_step
  transition :reject, to: :rejected
end
```

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
  manual true

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
  manual true
  transition :reject, to: :rejected
end

step :interview do
  manual true
  transition :reject, to: :rejected
end

# Same name, different targets — one action, routes based on current state
step :initial_review do
  manual true
  transition :complete, to: :detailed_review
end

step :detailed_review do
  manual true
  transition :complete, to: :done
end
```

### Conditional transitions

A transition can route to different states based on record attributes using conditional routes. The workflow evaluates conditions at runtime and picks the first match:

```elixir
step :review do
  manual true

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

Terminal steps are end states with no outgoing transitions, actions, or timeouts:

```elixir
step :approved, terminal: true
step :rejected, terminal: true
```

## Initial state

The first non-terminal step in declaration order becomes the initial state. The extension sets `default_initial_state` and `initial_states` on the generated state machine.

```elixir
workflow do
  step :intake do        # ← this is the initial state
    action :run_intake
    on_success :review
  end

  step :review do
    manual true
    transition :approve, to: :done
  end

  step :done, terminal: true
end
```
