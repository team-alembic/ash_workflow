# Getting Started with AshWorkflow

AshWorkflow lets you define multi-step workflows — combining human actions, background jobs, and time-based deadlines — as a single Ash resource. This guide walks you through building a simple document approval workflow.

## Installation

You need an existing Ash project. Install AshWorkflow with Igniter:

```bash
mix igniter.install ash_workflow
```

That adds `ash_workflow`, `ash_oban` and `ash_state_machine` as dependencies, composes `ash_oban.install` to configure Oban and its cron plugin, adds the `:workflow` queue that generated triggers publish to, and imports the workflow DSL into `.formatter.exs`. Pass `--queue` and `--queue-concurrency` to change the queue it adds. See `mix ash_workflow.install`.

Add `ash_workflow` to your dependencies and nothing else. Do not add `AshStateMachine` to the resource's `extensions` — `AshWorkflow.Transformers.AddStateMachine` adds it and writes its DSL for you. Add `AshOban` yourself, because the scheduler that generates its triggers is one choice among several; see `AshWorkflow.Scheduler`.

### Installing by hand

Without Igniter, add the dependencies yourself and configure Oban with a queue for workflow triggers:

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10, workflow: 5]
```

The queue name must match the workflow's `queue` option, which defaults to `:workflow`. A trigger publishing to a queue Oban does not run inserts jobs that never execute.

## Define the workflow

Create a resource with the `AshWorkflow` and `AshOban` extensions.

```elixir
defmodule MyApp.DocumentApproval do
  use Ash.Resource,
    domain: MyApp.Documents,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :auto_check do
      action :run_checks
      on_success :review
      on_error :check_failed
    end

    step :review do
      transition :approve, to: :approved
      transition :reject, to: :rejected

      timeout :reminder, fire_after: {3, :days}, action: :send_reminder
    end

    step :approved, terminal: true
    step :rejected, terminal: true
    step :check_failed, terminal: true
  end

  code_interface do
    define :create
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false
    attribute :author, :string, allow_nil?: false
  end

  actions do
    create :create do
      accept [:title, :author]
    end

    # Automatic steps need user-defined actions.
    # The extension injects transition_state + state_entered_at changes.
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
- A **primary read action** with keyset pagination
- **Code interface functions** for the manual transitions: `approve/1`, `reject/1`
- A **`state_entered_at`** attribute to track when the current state was entered
- The resource's own create action initializes the workflow using the initial step and `state_entered_at` defaults

> #### You define the create action {: .warning}
>
> AshWorkflow does not generate one. A workflow record's creation inputs are specific to your application, so the extension leaves `create` to you and only adds the changes that set the initial state and `state_entered_at`. A resource with a `workflow` block and no create action compiles, and then nothing can start a workflow.

`:auto_check` becomes the initial state because it is the first step by declaration order that is not terminal. `AshWorkflow.Entities.Step.find_initial/1` picks it. To name the initial step instead of relying on declaration order, mark it:

```elixir
workflow do
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

Without `initial true` that workflow would start in `:review`, because `:review` is declared first. A step that declares transitions has to set `initial` inside its block: `step :intake, initial: true do ... end` does not compile, because the DSL macro takes either options or a block.

## Use the workflow

```elixir
# Create a new workflow instance
{:ok, doc} = MyApp.DocumentApproval.create(%{title: "Q1 Report", author: "alice"})
# doc.state => :auto_check

# The auto_check step runs automatically via Oban.
# If your run_checks action succeeds, the state moves to :review.

# A reviewer approves:
{:ok, doc} = MyApp.DocumentApproval.approve(doc, actor: reviewer)
# doc.state => :approved
```

## Using AshPhoenix forms

Because workflow initialization happens through your normal create action, an `AshPhoenix.Form` targets that action directly:

```elixir
form =
  AshPhoenix.Form.for_create(
    MyApp.DocumentApproval,
    :create,
    domain: MyApp.Documents,
    as: "document_approval"
  )
```

Submitting that form creates the workflow record with your form values, while AshWorkflow fills in the initial `state` and `state_entered_at` automatically. That means the first workflow step is implicit: the form just creates the resource, and the workflow starts in its initial step.

## Adding authorization

To restrict who can trigger transitions, add a `policy` to the step and configure the authorizer:

```elixir
use Ash.Resource,
  domain: MyApp.Documents,
  data_layer: AshPostgres.DataLayer,
  authorizers: [Ash.Policy.Authorizer],
  extensions: [AshWorkflow, AshOban]

workflow do
  step :review do
    policy actor_attribute_equals(:role, :reviewer)

    transition :approve, to: :approved
    transition :reject, to: :rejected
  end

  # ...
end
```

Now only actors with `role: :reviewer` can call `:approve` or `:reject`. Other workflow actions, including create actions without an explicit policy, are allowed by the extension's default allow-all policy for uncovered workflow actions.

## Oban queue configuration

All generated Oban triggers use the `:workflow` queue by default. Make sure it's configured:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10, workflow: 5]
```

## Querying available actions

AshWorkflow provides two ways to discover what actions can be taken at a given step.

### Static introspection

Use `AshWorkflow.Info` to look up available transitions at compile time or from a module:

```elixir
AshWorkflow.Info.available_actions(MyApp.DocumentApproval, :review)
#=> [:approve, :reject]

AshWorkflow.Info.available_actions(MyApp.DocumentApproval, :approved)
#=> []
```

### Step metadata calculations

Every workflow resource also gets `:steps` and `:current_step` calculations:

```elixir
doc = Ash.load!(doc, [:steps, :current_step])
doc.steps
#=> [:auto_check, :review, :approved, :rejected, :check_failed]
doc.current_step
#=> :review
```

These are useful for rendering progress bars, step lists, or workflow visualisations.

The `:workflow_terminated_at` calculation returns the time the record entered a terminal step. It is `nil` while the workflow is still running. Set `terminated_at_calculation` in the `workflow` section to give it another name. It is an expression, so it can be used in filters and sorts:

```elixir
Document
|> Ash.Query.filter(workflow_terminated_at > ago(7, :day))
|> Ash.read!()
```

### Runtime calculation

Every workflow resource gets a generated `:available_actions` calculation. Load it on a record to get the transitions for its current state:

```elixir
doc = Ash.load!(doc, :available_actions)
doc.available_actions
#=> [:approve, :reject]
```

When an actor is provided, the calculation filters to only the actions that actor is authorized to perform:

```elixir
doc = Ash.load!(doc, :available_actions, actor: current_user)
doc.available_actions
#=> [:approve]  # only actions this user can perform
```

This is useful for building dynamic UIs that only show relevant buttons, or for agents and APIs that need to discover available actions without hard-coding workflow knowledge.

### Where a transition would go

A conditional transition picks its target when it runs. To label a button by where it leads, load `:transition_targets`. It maps each transition of the current step to the step it would move the record to:

```elixir
doc = Ash.load!(doc, :transition_targets)
doc.transition_targets
#=> %{approve: :approved, reject: :rejected}
```

For one transition, call `AshWorkflow.Info.transition_target/3`:

```elixir
AshWorkflow.Info.transition_target(doc, :approve)
#=> {:ok, :approved}
```

Both resolve routes through the same code the generated action runs, so the preview and the transition agree. A transition maps to `nil` when no route matches. `transition_target/3` also returns `{:ok, nil}` for a transition the current step does not declare, and `{:error, error}` when a route fails to evaluate.

A preview has no action input. A route that reads an accepted attribute sees the value on the record, not the one a caller is about to submit. To preview a particular call, pass the input: `AshWorkflow.Info.transition_target(doc, :decide, %{decision: :approve})`.

`transition_target/3` loads nothing, and a route that reads an unloaded relationship sees `nil`. The generated action reads the record it is called on the same way. The calculation loads the fields its routes reference.

## Stale transitions are refused

A transition decides from the record it is called on. It checks the step the record is in and picks a route from the record's attributes, then writes by primary key. A page loaded before someone else moved the record hands the action an old copy. Without a check, the transition would run from a step the record has already left, or take a route from values that have since changed. Of two reviewers who click at once, the second would overwrite the first.

AshWorkflow refuses such a transition. Take this step:

```elixir
workflow do
  step :screening do
    transition :advance do
      route :interviewing, when: expr(is_nil(path_type) or path_type == :agency)
      route :compliance, when: expr(path_type == :family)
    end

    transition :reject, to: :rejected
  end
end
```

Each transition writes only if the row still holds what the transition decided from: the state, and every attribute of the resource that a route of the loaded step reads. Here that is `state` and `path_type`. A `nil` value must still be `nil`. When the row has moved on, the call fails with `Ash.Error.Changes.StaleRecord` and the row stays as it was. Reload the record and try again.

```elixir
{:error, %Ash.Error.Invalid{errors: errors}} = Ash.update(stale_doc, action: :advance)
Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
#=> true
```

The struct a transition was called on is itself stale once the transition writes. Run the next transition on the struct it returned.

A change to an attribute no route reads does not make the copy stale. An attribute the call supplies through `accept` is not checked, since the route reads the supplied value.

- **Covered:** every manual transition, including one merged into an action you define, and `undo`. Undo from an old copy would otherwise reverse a transition the caller never saw.
- **Not covered:** automatic step actions, timeouts and error paths. The scheduler reads the record just before it runs them. A refusal on an automatic step would also count as the step failing and send the record down `on_error`.
- **Not checked:** a route reading a relationship, such as `sponsor.name`, or a calculation or aggregate. They are not values on the row. Copy the value onto the resource if a route must be protected against it changing.
- **Data layers:** the check needs a data layer that can filter an update, such as `AshPostgres.DataLayer` or `Ash.DataLayer.Ets`. On one that cannot, such as `Ash.DataLayer.Simple`, nothing is checked. It works on both the atomic and the non-atomic update path, so `require_atomic?` does not change it.

## Next steps

- See [Automatic vs Manual Steps](documentation/topics/automatic-vs-manual-steps.md) for a deeper dive
- See [Timeouts and Deadlines](documentation/topics/timeouts-and-deadlines.md) for time-based workflow control
- See [Authorization](documentation/topics/authorization.md) for policy patterns
