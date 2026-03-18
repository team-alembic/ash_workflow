# AshWorkflow

Declarative workflow orchestration for [Ash Framework](https://ash-hq.org). Define multi-step workflows that combine human actions, background jobs, and time-based deadlines — all as a single, readable DSL.

AshWorkflow generates [ash_state_machine](https://hexdocs.pm/ash_state_machine) states and transitions, [ash_oban](https://hexdocs.pm/ash_oban) triggers for automatic steps, and Ash actions for manual transitions. You write the workflow; it handles the wiring.

## Concepts

- **Step** — a state the workflow can be in. Some steps run automatically (background work via Oban), others wait for a human to trigger a transition.
- **Transition** — a named outcome from a manual step that moves the workflow to a new state. Each transition becomes a callable Ash action.
- **Timeout** — a time-based rule: "if the workflow has been in this state for N days, do X." Timeouts can run actions (reminders) or force transitions (escalations).
- **Terminal step** — an end state with no outgoing transitions (e.g., `:completed`, `:rejected`).

## Example: ATS Candidate Pipeline

```elixir
defmodule MyApp.CandidatePipeline do
  use Ash.Resource,
    domain: MyApp.Recruiting,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow]

  workflow do
    step :process_application do
      action :process_application
      on_success :recruiter_review
      on_error :application_failed
    end

    step :recruiter_review do
      manual true
      policy actor_attribute_equals(:role, :recruiter)

      transition :approve, to: :phone_screen
      transition :reject, to: :rejected

      timeout :reminder, after: {2, :days}, action: :send_review_reminder
      timeout :escalation, after: {7, :days}, transition_to: :escalated_review
    end

    step :phone_screen do
      action :schedule_phone_screen
      on_success :awaiting_screen_result
    end

    step :awaiting_screen_result do
      manual true
      policy actor_attribute_equals(:role, :recruiter)

      transition :pass, to: :onsite_interview
      transition :fail, to: :rejected
      transition :reschedule, to: :phone_screen

      timeout :nudge, after: {5, :days}, action: :remind_interviewer
    end

    step :onsite_interview do
      action :schedule_onsite
      on_success :awaiting_onsite_result
    end

    step :awaiting_onsite_result do
      manual true
      policy actor_attribute_equals(:role, :hiring_manager)

      transition :offer, to: :send_offer
      transition :reject, to: :rejected
    end

    step :send_offer do
      action :send_offer_email
      on_success :awaiting_offer_response
    end

    step :awaiting_offer_response do
      manual true

      transition :accept, to: :onboarding
      transition :decline, to: :offer_declined
      transition :negotiate, to: :send_offer

      timeout :follow_up, after: {3, :days}, action: :send_offer_reminder, repeat: true
      timeout :expire, after: {14, :days}, transition_to: :offer_expired
    end

    step :onboarding do
      action :start_onboarding_tasks
      terminal true
    end

    step :rejected, terminal: true
    step :offer_declined, terminal: true
    step :offer_expired, terminal: true
    step :application_failed, terminal: true
    step :escalated_review, terminal: true
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :candidate_name, :string, allow_nil?: false
    attribute :position, :string, allow_nil?: false
  end
end
```

## Automatic vs Manual Steps

**Automatic steps** (the default) run via Oban as soon as the workflow enters that state. Define them with `action`, `on_success`, and optionally `on_error`:

```elixir
step :send_offer do
  action :send_offer_email
  on_success :awaiting_offer_response
  on_error :offer_send_failed
end
```

The extension generates an Oban trigger that fires when the workflow's state matches the step name. Your action contains the business logic; the extension handles the state transition and scheduling.

**Manual steps** wait for a human (or external system) to call a transition action. Define them with `manual true` and one or more `transition` declarations:

```elixir
step :recruiter_review do
  manual true

  transition :approve, to: :phone_screen
  transition :reject, to: :rejected
end
```

Each transition becomes a generated Ash update action. You can call them through the code interface:

```elixir
CandidatePipeline.approve(workflow, actor: current_user)
CandidatePipeline.reject(workflow, actor: current_user)
```

## Authorization

Authorization works at two levels.

### Step-level policies

Use `policy` inside a step to restrict all transitions in that step to a particular kind of actor. The policy is applied to every generated transition action for that step:

```elixir
step :awaiting_onsite_result do
  manual true
  policy actor_attribute_equals(:role, :hiring_manager)

  transition :offer, to: :send_offer
  transition :reject, to: :rejected
end
```

This generates:

```elixir
policies do
  policy action([:offer, :reject]) do
    authorize_if actor_attribute_equals(:role, :hiring_manager)
  end
end
```

### Resource-level policies

For anything more complex — relationship-based checks, multi-condition rules, custom policy modules — define policies directly on the resource. The generated transition actions have predictable names (the transition name), so you can target them:

```elixir
policies do
  policy action(:approve) do
    authorize_if relates_to_actor_via(:assigned_recruiter)
  end

  policy action(:offer) do
    authorize_if actor_attribute_equals(:role, :hiring_manager)
    authorize_if Custom.IsInOfferingWindow
  end
end
```

When the transformer detects that you've defined policies targeting a transition action, it skips generating policies for that action from the step-level `policy` declaration.

## Timeouts and Deadlines

Timeouts let you react to a workflow being stuck in a state. They're implemented as scheduled Oban jobs that check whether the workflow is still in the expected state before acting.

```elixir
step :recruiter_review do
  manual true

  transition :approve, to: :phone_screen
  transition :reject, to: :rejected

  # Send a reminder after 2 days, but stay in the same state
  timeout :reminder, after: {2, :days}, action: :send_review_reminder

  # Force a transition after 7 days
  timeout :escalation, after: {7, :days}, transition_to: :escalated_review
end
```

**Action timeouts** run an Ash action but don't change state. Use these for reminders, notifications, or logging. Add `repeat: true` to re-fire on the same interval:

```elixir
timeout :follow_up, after: {3, :days}, action: :send_offer_reminder, repeat: true
```

**Transition timeouts** force the workflow into a new state. Use these for escalations, expirations, or SLA enforcement.

The extension auto-manages a `state_entered_at` timestamp attribute on the resource to track when the current state was entered. Timeout durations are calculated from this timestamp.

## What Gets Generated

From the workflow DSL, the extension generates:

| Layer | What | How |
|-------|------|-----|
| **State machine** | States, transitions, initial state | Via `ash_state_machine` DSL injection |
| **Oban triggers** | One trigger per automatic step | Via `ash_oban` DSL injection |
| **Transition actions** | One update action per manual transition | Ash update actions with `transition_state` change |
| **Timeout jobs** | Scheduled Oban jobs per timeout | Check state + run action or force transition |
| **Policies** | Step-level `policy` declarations | Ash policies on generated transition actions |
| **Code interface** | `start/1`, plus each transition name | Ash code interface definitions |
| **Attributes** | `state`, `state_entered_at` | Added if not already defined |

All generation follows a **generate-if-missing** pattern: if you've already defined a state machine block, Oban triggers, or policies targeting specific actions, the transformer won't overwrite them.

## Installation

Add `ash_workflow` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_workflow, "~> 0.1.0"}
  ]
end
```

## Status

This library is in early development. The DSL design is stabilizing but the implementation is incomplete. Contributions and feedback welcome.
