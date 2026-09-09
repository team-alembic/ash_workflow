# Authorization

AshWorkflow integrates with Ash's policy system to control who can trigger workflow transitions.

## Step-level policies

Add a `policy` to a manual step to restrict all its transitions to a specific kind of actor:

```elixir
step :manager_review do
  policy actor_attribute_equals(:role, :manager)

  transition :approve, to: :approved
  transition :reject, to: :rejected
end
```

This generates an Ash policy targeting both `:approve` and `:reject`:

```elixir
policies do
  policy action([:approve, :reject]) do
    authorize_if actor_attribute_equals(:role, :manager)
  end
end
```

### Available checks

The `policy` field accepts any `{module, opts}` tuple implementing `Ash.Policy.Check`. Common checks available inside the step block:

```elixir
policy actor_attribute_equals(:role, :admin)
policy relates_to_actor_via(:assigned_to)
policy actor_present()
```

For checks not imported by default, pass the tuple directly:

```elixir
policy {MyApp.Checks.BelongsToTeam, []}
```

### Default allow-all policy

When any step has a `policy` declaration, the extension generates a default "allow all" policy at the end of the policy list. This ensures workflow actions without explicit policies, like create actions and automatic step actions, aren't blocked.

## Resource-level policies

For complex authorization — multi-condition rules, relationship checks, or custom modules — define policies directly on the resource:

```elixir
policies do
  policy action(:approve) do
    authorize_if relates_to_actor_via(:assigned_reviewer)
    authorize_if actor_attribute_equals(:role, :admin)
  end
end
```

The extension skips generating step-level policies for actions that already have user-defined policies targeting them.

## Enabling the authorizer

Step-level policies only take effect if the resource has `Ash.Policy.Authorizer` configured:

```elixir
use Ash.Resource,
  domain: MyApp.Domain,
  data_layer: AshPostgres.DataLayer,
  authorizers: [Ash.Policy.Authorizer],
  extensions: [AshWorkflow, AshOban]
```

Without the authorizer, policies are defined but not enforced.

## Querying permitted actions

The generated `:available_actions` calculation is authorization-aware. When loaded with an actor, it returns only the actions that actor is permitted to perform:

```elixir
# Without actor — returns all transitions for the current step
doc = Ash.load!(doc, :available_actions)
doc.available_actions
#=> [:approve, :reject]

# With actor — filtered by policies
doc = Ash.load!(doc, :available_actions, actor: %{role: :viewer})
doc.available_actions
#=> []

doc = Ash.load!(doc, :available_actions, actor: %{role: :manager})
doc.available_actions
#=> [:approve, :reject]
```

This uses `Ash.can?/2` under the hood to check each action against the actor's permissions.

## SAT solver dependency

Ash's policy authorizer requires a SAT solver at compile time. Add one of these to your `mix.exs`:

```elixir
{:picosat_elixir, "~> 0.2"}  # recommended for production (NIF)
{:simple_sat, "~> 0.1"}      # pure Elixir alternative
```
