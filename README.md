# AshWorkflow

Declarative workflow orchestration for [Ash Framework](https://ash-hq.org). Define multi-step workflows that combine human actions, background jobs, and time-based deadlines — all as a single, readable DSL.

AshWorkflow generates [ash_state_machine](https://hexdocs.pm/ash_state_machine) states and transitions, [ash_oban](https://hexdocs.pm/ash_oban) triggers for automatic steps, and Ash actions for manual transitions. You write the workflow; it handles the wiring.

## Concepts

- **Step** — a state the workflow can be in. Some steps run automatically (background work via Oban), others wait for a human to trigger a transition.
- **Transition** — a named outcome from a manual step that moves the workflow to a new state. Each transition becomes a callable Ash action. Transition names must be unique across all steps.
- **Timeout** — a time-based rule: "if the workflow has been in this state for N days, do X." Timeouts can run actions (reminders) or force transitions (escalations).
- **Terminal step** — an end state with no outgoing transitions (e.g., `:rejected`, `:completed`).

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
      transition :reject_application, to: :rejected

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
      transition :reject_candidate, to: :rejected
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

      timeout :expire, after: {14, :days}, transition_to: :offer_expired
    end

    step :onboarding do
      action :start_onboarding_tasks
      on_success :hired
    end

    step :hired, terminal: true
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

  # Automatic steps need user-defined actions with business logic.
  # The extension injects transition_state and state_entered_at changes.
  actions do
    update :process_application do
      accept []
      change MyApp.Changes.ParseResume
    end

    update :schedule_phone_screen do
      accept []
      change MyApp.Changes.SendCalendlyLink
    end

    update :schedule_onsite do
      accept []
      change MyApp.Changes.SendOnsiteInvite
    end

    update :send_offer_email do
      accept []
      change MyApp.Changes.GenerateAndSendOffer
    end

    update :start_onboarding_tasks do
      accept []
      change MyApp.Changes.CreateOnboardingChecklist
    end

    update :send_review_reminder do
      accept []
      change MyApp.Changes.NotifyRecruiter
    end

    update :remind_interviewer do
      accept []
      change MyApp.Changes.NudgeInterviewer
    end
  end
end
```

## Automatic vs Manual Steps

**Automatic steps** (the default) run via Oban as soon as the workflow enters that state. You define the update action with your business logic; the extension injects `transition_state` and `state_entered_at` changes into it and generates an Oban trigger:

```elixir
step :send_offer do
  action :send_offer_email
  on_success :awaiting_offer_response
  on_error :offer_send_failed
end

# You define this action — the extension appends transition changes to it:
actions do
  update :send_offer_email do
    accept []
    change MyApp.Changes.GenerateAndSendOffer
  end
end
```

**Manual steps** wait for a human (or external system) to call a transition action. Define them with `manual true` and one or more `transition` declarations:

```elixir
step :recruiter_review do
  manual true

  transition :approve, to: :phone_screen
  transition :reject_application, to: :rejected
end
```

Each transition becomes a generated Ash update action. You can call them through the code interface:

```elixir
CandidatePipeline.approve(workflow, actor: current_user)
CandidatePipeline.reject_application(workflow, actor: current_user)
```

## Conditional Transitions

Transitions can route to different states based on record attributes:

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

The user calls `:complete_review` — the workflow evaluates conditions at runtime using `Ash.Expr` and routes to the first match. If no condition matches, the action fails with a clear error. Conditions have access to all record attributes.

## Authorization

Authorization works at two levels.

### Step-level policies

Use `policy` inside a step to restrict all transitions in that step to a particular kind of actor. The policy is applied to every generated transition action for that step. Supports any `{module, opts}` tuple implementing `Ash.Policy.Check`:

```elixir
step :awaiting_onsite_result do
  manual true
  policy actor_attribute_equals(:role, :hiring_manager)

  transition :offer, to: :send_offer
  transition :reject_candidate, to: :rejected
end
```

This generates:

```elixir
policies do
  policy action([:offer, :reject_candidate]) do
    authorize_if actor_attribute_equals(:role, :hiring_manager)
  end
end
```

**Important:** When using step-level policies, add `authorizers: [Ash.Policy.Authorizer]` to your resource. The extension generates a default "allow all" policy for actions without explicit policies (like `:start`), so only the step-level actions require the specified check.

### Resource-level policies

For anything more complex — relationship-based checks, multi-condition rules, custom policy modules — define policies directly on the resource. The generated transition actions have predictable names (the transition name), so you can target them:

```elixir
policies do
  policy action(:approve) do
    authorize_if relates_to_actor_via(:assigned_recruiter)
  end
end
```

When the transformer detects that you've defined policies targeting a transition action, it skips generating policies for that action from the step-level `policy` declaration.

## Timeouts and Deadlines

Timeouts let you react to a workflow being stuck in a state. They're implemented as Oban triggers that poll on a cron schedule (default: every minute) and check whether the workflow has been in the expected state long enough.

```elixir
step :recruiter_review do
  manual true

  transition :approve, to: :phone_screen
  transition :reject_application, to: :rejected

  # Send a reminder after 2 days, but stay in the same state
  timeout :reminder, after: {2, :days}, action: :send_review_reminder

  # Force a transition after 7 days
  timeout :escalation, after: {7, :days}, transition_to: :escalated_review
end
```

**Action timeouts** run an Ash action but don't change state. Use these for reminders, notifications, or logging.

**Transition timeouts** force the workflow into a new state. Use these for escalations, expirations, or SLA enforcement.

The polling interval is configurable per-timeout via `check_interval` (defaults to `"* * * * *"`):

```elixir
timeout :daily_check, after: {3, :days}, action: :check_status, check_interval: "0 9 * * *"
```

The extension auto-manages a `state_entered_at` timestamp attribute on the resource to track when the current state was entered. Timeout durations are calculated from this timestamp.

Supported duration units: `:seconds`, `:minutes`, `:hours`, `:days`.

## What Gets Generated

From the workflow DSL, the extension generates:

| Layer | What | How |
|-------|------|-----|
| **Extensions** | AshStateMachine, AshOban | Auto-added via `add_extensions` |
| **State machine** | States, transitions, initial state | Via `ash_state_machine` DSL injection |
| **Oban triggers** | One trigger per automatic step + timeouts | Via `ash_oban` DSL injection |
| **Actions** | `:start` create, one update per transition, read | Ash actions with `transition_state` change |
| **Timeout actions** | Hidden `__timeout_*` update actions | For timeouts with `transition_to` |
| **Policies** | Step-level `policy` declarations | Ash policies on generated transition actions |
| **Code interface** | `start/1`, plus each transition name | Ash code interface definitions |
| **Attributes** | `state_entered_at` | Added if not already defined |

The initial state is the first non-terminal step by declaration order.

All generation follows a **generate-if-missing** pattern: if you've already defined a read action, policies targeting specific actions, or code interface definitions, the transformers won't overwrite them.

## Installation

Add `ash_workflow` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_workflow, "~> 0.1.0"}
  ]
end
```

You do **not** need to add `ash_state_machine` or `ash_oban` to your extensions list — `AshWorkflow` includes them automatically. You do still need both as dependencies in your `mix.exs`.

## Status

This library is in active development. The core DSL and generation pipeline are functional — state machine, actions, Oban triggers, timeouts, policies, and code interface are all implemented. `repeat: true` on timeouts is accepted but not yet fully implemented.
