# AshWorkflow Authorization Patterns

## Step-Level Policies

The simplest authorization model is declaring a `policy` on a manual step. This applies the check to every transition in that step.

```elixir
step :manager_review do
  manual true
  policy actor_attribute_equals(:role, :manager)

  transition :approve, to: :approved
  transition :reject, to: :rejected
  transition :defer, to: :deferred
end
```

All three transitions (approve, reject, defer) require the actor to have `role: :manager`.

## Available Built-In Checks

Inside a `step` block, these checks are imported automatically from `Ash.Policy.Check.Builtins`:

- `actor_attribute_equals(attribute, value)` — checks that the actor's attribute matches the given value
- `relates_to_actor_via(relationship_path)` — checks that the record is related to the actor through the given relationship
- `actor_present()` — checks that an actor is provided

```elixir
step :author_review do
  manual true
  policy relates_to_actor_via(:author)
  transition :submit, to: :submitted
end

step :any_authenticated do
  manual true
  policy actor_present()
  transition :acknowledge, to: :acknowledged
end
```

## Resource-Level Policies

For more granular control, use standard Ash policies on the resource. Target the generated action names directly.

```elixir
policies do
  # Different roles for different transitions
  policy action(:approve) do
    authorize_if actor_attribute_equals(:role, :manager)
  end

  policy action(:reject) do
    authorize_if actor_attribute_equals(:role, :manager)
    authorize_if actor_attribute_equals(:role, :admin)
  end

  # Compound conditions
  policy action(:offer) do
    authorize_if relates_to_actor_via(:assigned_recruiter)
  end
end
```

When you define a resource-level policy targeting a specific transition action, the step-level `policy` is not applied for that action. This lets you override individual transitions.

## Multi-Role Workflows

For workflows involving different roles at different stages, use step-level policies:

```elixir
workflow do
  step :recruiter_screen do
    manual true
    policy actor_attribute_equals(:role, :recruiter)

    transition :advance, to: :interview
    transition :reject, to: :rejected
  end

  step :interview do
    manual true
    policy actor_attribute_equals(:role, :interviewer)

    transition :pass, to: :hiring_manager_review
    transition :fail, to: :rejected
  end

  step :hiring_manager_review do
    manual true
    policy actor_attribute_equals(:role, :hiring_manager)

    transition :offer, to: :generate_offer
    transition :reject, to: :rejected
  end
end
```

## Automatic Steps and Authorization

Automatic steps run via Oban background jobs and do not have actors by default. If your automatic step's action requires authorization, you need to configure actor persistence in your Oban setup. Step-level `policy` is only meaningful for manual steps.

## Calling Transitions with an Actor

Pass the actor when calling transition actions:

```elixir
MyResource.approve(record, actor: current_user)
MyResource.reject(record, %{reason: "Missing data"}, actor: current_user)
```

If a step has a policy and no actor is provided, the transition will fail with an authorization error.
