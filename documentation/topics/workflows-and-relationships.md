# Workflows and Relationships

A workflow rarely exists in isolation. It typically tracks a process for a related business entity — a candidate, an order, a document. This guide covers the common patterns for connecting workflows to other resources.

## Workflow on the resource itself

The simplest approach: the resource *is* the workflow. The state machine lives directly on the business entity.

```elixir
defmodule MyApp.SupportTicket do
  use Ash.Resource,
    extensions: [AshWorkflow]

  workflow do
    step :triage do
      transition :assign, to: :in_progress
      transition :close_as_duplicate, to: :closed
    end

    step :in_progress do
      transition :resolve, to: :resolved
      transition :escalate, to: :escalated
    end

    step :resolved, terminal: true
    step :closed, terminal: true
    step :escalated, terminal: true
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false
    attribute :description, :string
    attribute :priority, :atom, constraints: [one_of: [:low, :medium, :high]]
  end
end
```

This works well when the entity and the workflow have the same lifecycle — the ticket is created, goes through states, and ends. No separate tracking resource needed.

## Separate workflow tracking a related resource

When the business entity has a lifecycle independent of the workflow, or when the same entity can go through a workflow multiple times, use a separate workflow resource with a `belongs_to` relationship.

```elixir
defmodule MyApp.WorkerCandidate do
  use Ash.Resource,
    domain: MyApp.Workforce

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :email, :string, allow_nil?: false
  end

  relationships do
    has_many :onboarding_workflows, MyApp.OnboardingWorkflow
  end
end

defmodule MyApp.OnboardingWorkflow do
  use Ash.Resource,
    domain: MyApp.Workforce,
    extensions: [AshWorkflow]

  workflow do
    step :screening do
      transition :approve, to: :interviewing
      transition :reject_at_screening, to: :rejected
    end

    step :interviewing do
      transition :pass, to: :offer
      transition :fail, to: :rejected
    end

    step :offer do
      transition :accept, to: :activated
      transition :decline, to: :withdrawn
    end

    step :activated, terminal: true
    step :rejected, terminal: true
    step :withdrawn, terminal: true
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :rejection_reason, :string
    attribute :offer_accepted_at, :utc_datetime_usec
    timestamps()
  end

  relationships do
    belongs_to :worker_candidate, MyApp.WorkerCandidate do
      allow_nil? false
      attribute_writable? true
    end
  end
end
```

### Starting the workflow

Your create action can accept writable relationship attributes, including relationship attributes marked with `attribute_writable? true`. So if your workflow uses a create action named `:create`, starting a workflow for an existing candidate is:

```elixir
{:ok, workflow} = MyApp.OnboardingWorkflow.create(%{
  worker_candidate_id: candidate.id
})
```

If you want to create the candidate and workflow together, use a custom action or `manage_relationship` on your create action.

### Querying workflows for a resource

Standard Ash relationship queries work:

```elixir
# All workflows for a candidate
candidate |> Ash.load!(:onboarding_workflows)

# Active (non-terminal) workflows
MyApp.OnboardingWorkflow
|> Ash.Query.filter(worker_candidate_id == ^candidate.id and state not in [:activated, :rejected, :withdrawn])
|> Ash.read!()
```

## When to use which pattern

Use **workflow on the resource** when:
- The entity and workflow have the same lifecycle (created together, done together)
- There's only ever one workflow per entity
- The entity doesn't exist outside the workflow context

Use a **separate workflow resource** when:
- The entity exists independently (e.g., imported from an external system)
- The entity can go through the workflow multiple times (rejected, reapplied)
- You need to track multiple concurrent workflows for one entity
- You want to keep workflow history separate from the business entity

## Creating outcome records on terminal states

A common pattern: when a workflow reaches a terminal state, it creates or updates a related record. For example, an onboarding workflow that creates a Worker record on activation.

Handle this in the transition action with standard Ash changes:

```elixir
# User-defined action that the transition calls
actions do
  update :activate do
    accept []
    change set_attribute(:activated_at, &DateTime.utc_now/0)
    change MyApp.Changes.CreateWorkerFromCandidate
  end
end
```

```elixir
defmodule MyApp.Changes.CreateWorkerFromCandidate do
  use Ash.Resource.Change

  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, workflow ->
      candidate = Ash.load!(workflow, :worker_candidate).worker_candidate

      {:ok, worker} = MyApp.Worker.create!(%{
        name: candidate.name,
        email: candidate.email,
        onboarding_workflow_id: workflow.id
      })

      {:ok, Ash.Changeset.force_change_attribute(workflow, :worker_id, worker.id)}
    end)
  end
end
```

The workflow DSL handles the state transition; your change handles the business logic of creating related records.
