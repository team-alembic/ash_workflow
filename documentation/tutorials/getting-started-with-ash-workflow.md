# Getting Started with AshWorkflow

AshWorkflow lets you define multi-step workflows — combining human actions, background jobs, and time-based deadlines — as a single Ash resource. This guide walks you through building a simple document approval workflow.

## Prerequisites

- An existing Ash project with `ash_state_machine` and `ash_oban` as dependencies
- Oban configured in your application (with at least a `:workflow` queue)

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10, workflow: 5]
```

## Define the workflow

Create a resource with the `AshWorkflow` extension. You don't need to add `AshStateMachine` or `AshOban` — they're included automatically.

```elixir
defmodule MyApp.DocumentApproval do
  use Ash.Resource,
    domain: MyApp.Documents,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow]

  workflow do
    step :auto_check do
      action :run_checks
      on_success :review
      on_error :check_failed
    end

    step :review do
      manual true

      transition :approve, to: :approved
      transition :reject, to: :rejected

      timeout :reminder, after: {3, :days}, action: :send_reminder
    end

    step :approved, terminal: true
    step :rejected, terminal: true
    step :check_failed, terminal: true
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false
    attribute :author, :string, allow_nil?: false
  end

  # Automatic steps need user-defined actions.
  # The extension injects transition_state + state_entered_at changes.
  actions do
    update :run_checks do
      accept []
      change MyApp.Changes.ValidateDocument
    end

    update :send_reminder do
      accept []
      change MyApp.Changes.NotifyReviewer
    end
  end
end
```

## What this generates

From that DSL, AshWorkflow generates:

- A **state machine** with states `:auto_check`, `:review`, `:approved`, `:rejected`, `:check_failed`
- An **Oban trigger** for `:auto_check` that fires when `state == :auto_check`
- An **Oban trigger** for the reminder timeout that fires when `state == :review` and `state_entered_at <= ago(3, :day)`
- **Transition actions** `:approve` and `:reject` as update actions with `transition_state`
- A **`:start` create action** that accepts all writable attributes
- A **primary read action** with keyset pagination
- **Code interface functions**: `start/1`, `approve/1`, `reject/1`
- A **`state_entered_at`** attribute to track when the current state was entered

## Use the workflow

```elixir
# Create a new workflow instance
{:ok, doc} = MyApp.DocumentApproval.start(%{title: "Q1 Report", author: "alice"})
# doc.state => :auto_check

# The auto_check step runs automatically via Oban.
# If your run_checks action succeeds, the state moves to :review.

# A reviewer approves:
{:ok, doc} = MyApp.DocumentApproval.approve(doc, actor: reviewer)
# doc.state => :approved
```

## Adding authorization

To restrict who can trigger transitions, add a `policy` to the step and configure the authorizer:

```elixir
use Ash.Resource,
  domain: MyApp.Documents,
  data_layer: AshPostgres.DataLayer,
  authorizers: [Ash.Policy.Authorizer],
  extensions: [AshWorkflow]

workflow do
  step :review do
    manual true
    policy actor_attribute_equals(:role, :reviewer)

    transition :approve, to: :approved
    transition :reject, to: :rejected
  end

  # ...
end
```

Now only actors with `role: :reviewer` can call `:approve` or `:reject`. Other actions (like `:start`) are allowed for everyone — the extension generates a default allow-all policy for uncovered actions.

## Oban queue configuration

All generated Oban triggers use the `:workflow` queue by default. Make sure it's configured:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10, workflow: 5]
```

## Next steps

- See [Automatic vs Manual Steps](documentation/topics/automatic-vs-manual-steps.md) for a deeper dive
- See [Timeouts and Deadlines](documentation/topics/timeouts-and-deadlines.md) for time-based workflow control
- See [Authorization](documentation/topics/authorization.md) for policy patterns
