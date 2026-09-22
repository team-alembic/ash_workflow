# AshWorkflow

[![CI](https://github.com/team-alembic/ash_workflow/actions/workflows/ci.yml/badge.svg)](https://github.com/team-alembic/ash_workflow/actions/workflows/ci.yml)
[![Hex version](https://img.shields.io/hexpm/v/ash_workflow.svg)](https://hex.pm/packages/ash_workflow)
[![Hex downloads](https://img.shields.io/hexpm/dt/ash_workflow.svg)](https://hex.pm/packages/ash_workflow)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-purple.svg)](https://hexdocs.pm/ash_workflow)
[![License: MIT](https://img.shields.io/hexpm/l/ash_workflow.svg)](https://github.com/team-alembic/ash_workflow/blob/main/LICENSE)

Declarative workflow orchestration for [Ash Framework](https://ash-hq.org). Define multi-step workflows that combine human actions, background jobs, and time-based deadlines — all as a single, readable DSL.

AshWorkflow generates [ash_state_machine](https://hexdocs.pm/ash_state_machine) states and transitions, [ash_oban](https://hexdocs.pm/ash_oban) triggers for automatic steps, and Ash actions for manual transitions. You write the workflow; it handles the wiring.

## Installation

```bash
mix igniter.install ash_workflow
```

That adds the dependency and sets up everything the generated DSL needs to
run: Oban in your supervision tree via `AshOban.config/2`, the cron plugin,
the `:workflow` queue that generated triggers publish to, `:ash_domains`
config, and the formatter import for the workflow DSL.

Pass `--queue` and `--queue-concurrency` to change the queue it configures.

<details>
<summary>Manual installation</summary>

Add `ash_workflow` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_workflow, "~> 0.7"}
  ]
end
```

Then configure Oban with a `:workflow` queue and the cron plugin, and start it
with `AshOban.config/2`. See the
[ash_oban documentation](https://hexdocs.pm/ash_oban) for details.

</details>

`ash_state_machine` and `ash_oban` come in as dependencies of `ash_workflow`,
so do not declare them in `mix.exs` yourself. On the resource, add
`AshWorkflow` and `AshOban` to `extensions`, and leave `AshStateMachine` out:
`AshWorkflow.Transformers.AddStateMachine` adds that extension and writes its
DSL. `AshOban` stays explicit because the scheduler that generates its
triggers is one choice among several. See `AshWorkflow.Scheduler`.

## Concepts

- **Step** — a state the workflow can be in. Some steps run automatically (background work via Oban), others wait for a human to trigger a transition.
- **Transition** — a named outcome from a manual step that moves the workflow to a new state. Each transition becomes a callable Ash action. The same transition name can be used across multiple steps — they merge into a single action that routes based on the current state.
- **Timeout** — a time-based rule: "if the workflow has been in this state for N days, do X." Timeouts can run actions (reminders) or force transitions (escalations).
- **Every** — a recurring action that runs on an interval for as long as the record sits in a step, for nudges and chasers. Unlike a timeout, it always runs an action and never changes state.
- **Terminal step** — an end state. A step that declares no action, no transitions and no timeouts has no way out, so it is terminal without saying so. `terminal: true` states the intent and makes the verifier hold you to it.
- **Transition log** — an opt-in resource recording one row per workflow event, which becomes the source of truth for history.
- **Undo** — rewinding a record to the state before its last transition, for transitions marked `undoable?: true`. Recorded as a new log row pointing at the one it reverses, never by erasing history.

## Example: ATS Candidate Pipeline

```elixir
defmodule MyApp.CandidatePipeline do
  use Ash.Resource,
    domain: MyApp.Recruiting,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  workflow do
    # Automatic: runs as soon as a record enters the step
    step :process_application do
      action :process_application
      on_success :recruiter_review
      on_error :application_failed
    end

    # Manual: waits for someone to call a transition
    step :recruiter_review do
      policy actor_attribute_equals(:role, :recruiter)

      transition :approve, to: :phone_screen
      transition :reject_application, to: :rejected

      timeout :reminder, fire_after: {2, :days}, action: :send_review_reminder
      timeout :escalation, fire_after: {7, :days}, transition_to: :escalated_review
    end

    step :phone_screen do
      action :schedule_phone_screen
      on_success :awaiting_screen_result
    end

    step :awaiting_screen_result do
      policy actor_attribute_equals(:role, :recruiter)

      transition :pass, to: :hired
      transition :fail, to: :rejected
      transition :reschedule, to: :phone_screen

      every :nudge, {5, :days}, action: :remind_interviewer
    end

    step :hired, terminal: true
    step :rejected, terminal: true
    step :escalated_review, terminal: true
    step :application_failed, terminal: true
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :candidate_name, :string, allow_nil?: false
    attribute :position, :string, allow_nil?: false
  end

  # You write the actions an automatic step, a timeout or an `every` names.
  # The extension appends its own changes to them.
  actions do
    update :process_application do
      accept []
      change MyApp.Changes.ParseResume
    end

    update :send_review_reminder do
      accept []
      change MyApp.Changes.NotifyRecruiter
    end
  end
end
```

The full pipeline, with the onsite and offer stages, is in
[`examples/ats/candidate_pipeline.ex`](https://github.com/team-alembic/ash_workflow/blob/main/examples/ats/candidate_pipeline.ex).

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

**Manual steps** wait for a human (or external system) to call a transition action. Any step that declares one or more `transition` entries is a manual step:

```elixir
step :recruiter_review do
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
  transition :complete_review do
    route :fast_track, when: expr(priority == :urgent)
    route :standard_processing, when: expr(priority == :normal)
  end

  transition :reject_review, to: :rejected
end
```

The user calls `:complete_review` — the workflow evaluates conditions at runtime using `Ash.Expr` and routes to the first match. If no condition matches, the action fails with a clear error.

Conditions read the record as it was loaded, plus the attributes the transition accepts, so a transition can accept the value it routes on:

```elixir
step :review do
  transition :decide do
    accept [:decision]
    route :approved, when: expr(decision == :approve)
    route :rejected, when: expr(decision == :reject)
  end
end
```

`CandidatePipeline.decide(workflow, %{decision: :approve})` lands in `:approved`. An attribute written by one of the action's own changes is not visible to the routes, so a route can still ask what the record looked like before the call.

## Authorization

Authorization works at two levels.

### Step-level policies

Use `policy` inside a step to restrict all transitions in that step to a particular kind of actor. The policy is applied to every generated transition action for that step. Supports any `{module, opts}` tuple implementing `Ash.Policy.Check`:

```elixir
step :awaiting_onsite_result do
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

**Important:** When using step-level policies, add `authorizers: [Ash.Policy.Authorizer]` to your resource. The extension generates a default "allow all" policy scoped to the workflow actions that have no explicit policy of their own (the generated read action, automatic step actions, and timeout actions), so only the step-level actions require the specified check.

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

Three time-based rules live inside a step. All of them are polled by the
scheduler rather than scheduled per record.

```elixir
step :recruiter_review do
  transition :approve, to: :phone_screen

  # Runs an action and stays in the step
  timeout :reminder, fire_after: {2, :days}, action: :send_review_reminder

  # Forces a transition
  timeout :escalation, fire_after: {7, :days}, transition_to: :escalated_review

  # Fires on an instant the record already holds
  timeout :interview_due do
    fire_at :scheduled_for
    transition_to :interview_missed
  end

  # Recurs while the record sits here, and gives up after 8 days
  every :nudge do
    interval {2, :days}
    action :remind_interviewer
    until {8, :days}
  end
end
```

`fire_after` measures from `state_entered_at`, the attribute the extension
maintains, or from a datetime attribute named with `field`. `fire_at` names an
attribute or expression calculation that already holds the deadline instant, so
there is no offset to compute. `every` measures from its own
`<step>_<every>_last_fired_at` column rather than from `state_entered_at`, so
firing never pushes back a deadline beside it, and its first run lands one whole
interval after the record entered the step. `until` bounds the repetition
against `state_entered_at`, and reaching it stops the firing without changing
state.

Each timeout, each `every` and each automatic step gets its own Oban cron
scheduler that queries for records past their deadline. `check_interval` sets
how often, once on the `workflow` section or per entity, and defaults to every
minute:

```elixir
workflow do
  check_interval "0 * * * *"

  step :awaiting_review do
    transition :approve, to: :approved

    timeout :daily_check do
      fire_after {3, :days}
      action :check_status
      check_interval "0 9 * * *"
    end
  end
end
```

The cost scales with the number of triggers on the resource, not the number of
records — eight triggers at the default interval is 480 scheduler queries an
hour, whether or not anything is waiting. For workflows measured in days, an
hourly interval behaves the same to users at a fraction of the cost.
`AshWorkflow.Scheduler.Precise` arms a timer per deadline instead of polling,
for deadlines shorter than cron can ask for. See
[Timeouts and deadlines](documentation/topics/timeouts-and-deadlines.md) for
details.

Supported duration units: `:seconds`, `:minutes`, `:hours`, `:days`.

## What Gets Generated

From the workflow DSL, the extension generates:

| Layer | What | How |
|-------|------|-----|
| **Extensions** | AshStateMachine | Auto-added via `add_extensions`. Add `AshOban` yourself — see Scheduling |
| **State machine** | States, transitions, initial state | Via `ash_state_machine` DSL injection |
| **Scheduled work** | One `Scheduler.Work` per automatic step, timeout and `every` | Handed to the selected `AshWorkflow.Scheduler` |
| **Oban triggers** | One trigger per unit of work | `AshWorkflow.Scheduler.Oban`, the default |
| **Actions** | One update per transition, plus a read action | Ash actions with `transition_state` change |
| **Timeout actions** | Hidden `__timeout_*` update actions | For timeouts with `transition_to` |
| **Indexes** | One `(state, field)` composite per deadline field | `AshPostgres.DataLayer` resources; opt out with `generate_indexes? false` |
| **Policies** | Step-level `policy` declarations | Ash policies on generated transition actions |
| **Code interface** | One function per transition name | Ash code interface definitions |
| **Calculations** | `:steps`, `:current_step`, `:available_actions`, `:pending_deadlines` | Workflow introspection |
| **Attributes** | `state_entered_at`, plus one last-fired column per `every` | Added if not already defined |

The initial state is the step with `initial true`, or the first non-terminal step by declaration order if none is marked. Declaration order is easy to trip over, so mark the step when the reading order is not the running order:

```elixir
workflow do
  # Starts in :intake. Without `initial true` it would start in :review,
  # the first non-terminal step by declaration order.
  step :review do
    transition :approve, to: :approved
  end

  step :intake do
    initial true
    transition :submit, to: :review
  end

  step :approved, terminal: true
end
```

The current step lives in the `state` attribute. A resource that already has a lifecycle column of its own renames it with `state_attribute` on the `workflow` section, and everything generated follows the new name:

```elixir
workflow do
  state_attribute :status

  step :review do
    transition :approve, to: :approved
  end

  step :approved, terminal: true
end
```

`state_entered_at` keeps its name.

All generation follows a **generate-if-missing** pattern: if you've already defined a read action, policies targeting specific actions, or code interface definitions, the transformers won't overwrite them. The generated read is called `:read`, or `:__workflow_read` if your resource already has an action by that name.

Workflows are started through your own create action — AshWorkflow does not generate one. A newly created record enters the initial step implicitly, because `state_entered_at` defaults on create.

## Demos

Runnable applications live in [`demos/`](https://github.com/team-alembic/ash_workflow/tree/main/demos), each with its own test suite
that CI runs:

| Demo | What it shows |
|---|---|
| [`ats`](https://github.com/team-alembic/ash_workflow/tree/main/demos/ats) | A Phoenix LiveView app you can click through |
| [`document_approval`](https://github.com/team-alembic/ash_workflow/tree/main/demos/document_approval) | Conditional routes: two admins must sign off, so one `:approve` action does not advance the workflow the first time |
| [`order_fulfilment`](https://github.com/team-alembic/ash_workflow/tree/main/demos/order_fulfilment) | Error handling across a long automatic chain, with recovery looping back into it |
| [`subscription_dunning`](https://github.com/team-alembic/ash_workflow/tree/main/demos/subscription_dunning) | `every` for recurring actions, and deadlines measured against a date on the record |
| [`support_ticket_sla`](https://github.com/team-alembic/ash_workflow/tree/main/demos/support_ticket_sla) | Priority routing, one transition name meaning different things per step, per-queue SLAs |
| [`workflow_timeline`](https://github.com/team-alembic/ash_workflow/tree/main/demos/workflow_timeline) | The transition log rendered as a timeline, and undo as an append-only operation |

## Contributing

Bug reports and pull requests are welcome — see
[CONTRIBUTING.md](https://github.com/team-alembic/ash_workflow/blob/main/CONTRIBUTING.md).
This project follows the
[Contributor Covenant](https://github.com/team-alembic/ash_workflow/blob/main/CODE_OF_CONDUCT.md).

## License

MIT — see [LICENSE](https://github.com/team-alembic/ash_workflow/blob/main/LICENSE).
