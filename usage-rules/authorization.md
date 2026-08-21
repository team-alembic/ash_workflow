# AshWorkflow Authorization Patterns

## Step-Level Policies

The simplest authorization model is declaring a `policy` on a manual step. This applies the check to every transition in that step.

```elixir
step :manager_review do
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
  policy relates_to_actor_via(:author)
  transition :submit, to: :submitted
end

step :any_authenticated do
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
    policy actor_attribute_equals(:role, :recruiter)

    transition :advance, to: :interview
    transition :reject, to: :rejected
  end

  step :interview do
    policy actor_attribute_equals(:role, :interviewer)

    transition :pass, to: :hiring_manager_review
    transition :fail, to: :rejected
  end

  step :hiring_manager_review do
    policy actor_attribute_equals(:role, :hiring_manager)

    transition :offer, to: :generate_offer
    transition :reject, to: :rejected
  end
end
```

## Automatic Steps and Authorization

Automatic steps and timeouts run via Oban background jobs without an actor. AshWorkflow automatically injects an `AshOban.Checks.AshObanInteraction` bypass policy so these actions execute without authorization issues. This bypass only applies when the action is invoked by an Oban worker (i.e., `context.private.ash_oban?` is true) — it cannot be triggered by external callers.

Step-level `policy` is only meaningful for manual steps.

## Default Allow for Workflow Actions

When `Ash.Policy.Authorizer` is present on the resource, AshWorkflow injects a default `authorize_if always()` policy scoped to all workflow-generated actions (`:read`, transitions, automatic step actions, and timeout actions). This ensures workflow actions work out of the box without users needing to add a blanket allow policy.

Step-level policies are evaluated **in addition to** this default allow, so they act as restrictive gates on specific manual transitions.

## Calling Transitions with an Actor

Pass the actor when calling transition actions:

```elixir
MyResource.approve(record, actor: current_user)
MyResource.reject(record, %{reason: "Missing data"}, actor: current_user)
```

If a step has a policy and no actor is provided, the transition will fail with an authorization error.

## Do not share a transition name across steps with different policies

Steps that declare the same transition name merge into a single Ash action, and
each step's `policy` is applied to that action. Ash requires *every* applicable
policy to pass, so two different policies on the same action block each other
and nobody can call it.

```elixir
# Rejected at compile time
step :queue do
  policy actor_attribute_equals(:role, :agent)
  transition :resolve, to: :resolved
end

step :escalated do
  policy actor_attribute_equals(:role, :manager)
  transition :resolve, to: :resolved   # same name, different policy
end
```

AshWorkflow rejects this at compile time rather than letting it become a silent
runtime lockout. Three ways to model it instead:

1. **Distinct names per step** — `:resolve` in the queue, `:manager_resolve` in
   the escalated step. Clearest, and the generated actions stay meaningfully
   named.
2. **The same policy on both steps** — fine when the steps really do share an
   authorization rule.
3. **A resource-level policy** — drop the step-level `policy` and authorize the
   merged action yourself, where you can inspect the state:

   ```elixir
   policies do
     policy action(:resolve) do
       authorize_if expr(state == :escalated and ^actor(:role) == :manager)
       authorize_if expr(state != :escalated and ^actor(:role) == :agent)
     end
   end
   ```
