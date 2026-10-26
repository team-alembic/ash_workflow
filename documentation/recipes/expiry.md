# Expiry

`mix ash_workflow.gen.expiry` adds an expiry workflow to a resource. Each record gets an `expires_at`, moves to `:expiring` a notice period before it, moves to `:expired` once it passes, and returns to `:active` when it is renewed with a new date.

## The command

```bash
mix ash_workflow.gen.expiry MyApp.Contracts.Contract --notice-period 30d
```

| Option | Default | Effect |
|---|---|---|
| `--module` | `<Subject>Expiry` | Name of the generated expiry resource. |
| `--domain` | none | Domain for a subject the task creates. Required when the subject does not exist, and ignored when it does: the expiry resource then joins the subject's domain. |
| `--notice-period` | none | Moves an expiry to `:expiring` this long before `expires_at`. Accepts `10s`, `30m`, `12h`, `2d` and `2w`. Without it, no `:expiring` step is generated. |
| `--transition-log` | `true` | Also runs `mix ash_workflow.gen.transition_log` for the expiry resource. Pass `--no-transition-log` to skip it. |

When the subject does not exist, the task creates it with `mix ash.gen.resource`, using the data layer of the first ETS or Postgres resource in `--domain`. When no resource there uses ETS or Postgres, the task stops with an issue and writes nothing. Create the subject resource first, or pass a `--domain` that has one. Running the task again on the same subject changes nothing.

## What it generates

For the command above, the task writes four modules and edits the subject:

- `MyApp.Contracts.ContractExpiry` runs the workflow. It belongs to the contract and holds `expires_at`. Its `subject_id` takes the type of the contract's primary key, and the task reports an issue for a subject with a composite primary key. An identity on `subject_id` allows one expiry per contract.
- `MyApp.Contracts.ContractExpiry.Checks.CanCreate` decides who may create an expiry. It denies everyone as generated.
- `MyApp.Contracts.ContractExpiry.Checks.CanRenew` decides who may renew. It denies everyone as generated.
- `MyApp.Contracts.ContractExpiry.Changes.SetExpiry` is a change for the contract's actions. After the contract action succeeds, it creates the contract's expiry, or renews the one it has.
- `MyApp.Contracts.Contract` gains `has_one :expiry`, an `expired?` calculation, and an update action `:set_expiry` with a `set_expiry` code interface. `:set_expiry` takes an `expires_at` argument and runs `SetExpiry`. The task changes none of the subject's other actions.

A contract with no expiry never expires. Its `expired?` is `false`, and no timeout runs for it. Nothing creates an expiry until your application calls `:set_expiry` or adds `SetExpiry` to one of its own actions, as described in [Start the clock](#start-the-clock).

The expiry is a separate resource rather than a `workflow` block on the subject, so a subject that already runs a workflow keeps it.

## The workflow

```mermaid
stateDiagram-v2
  [*] --> active
  active --> expiring: expiring_at passes
  expiring --> expired: expires_at passes
  active --> active: renew
  expiring --> active: renew
  expired --> active: renew
```

```elixir
workflow do
  step :active do
    transition :renew, to: :active

    timeout :expiring do
      fire_at :expiring_at
      transition_to :expiring
    end
  end

  step :expiring do
    transition :renew, to: :active

    timeout :expired do
      fire_at :expires_at
      transition_to :expired
    end
  end

  step :expired do
    transition :renew, to: :active
  end
end

calculations do
  calculate :expiring_at, :utc_datetime_usec, expr(datetime_add(expires_at, -30, :day))
end
```

Without `--notice-period`, there is no `:expiring` step and no `expiring_at` calculation. The `:expired` timeout sits on `:active` instead.

Both deadlines read `expires_at`, and `expiring_at` is calculated from it. Renewing writes a new `expires_at`, which moves both deadlines. Neither timeout reads `state_entered_at`.

`:expired` is not terminal. An expired record stays expired until it is renewed.

An expiry created with `expires_at` already in the past moves to `:expiring` on the first scheduler pass and to `:expired` on the next.

## What your application does next

### Decide who may create an expiry

`CanCreate` denies everyone, so no expiry can be created until you change it. Replace its `match?/3`, or replace the `authorize_if` line in the `:create` policy with a built-in check:

```elixir
policies do
  policy action(:create) do
    authorize_if actor_attribute_equals(:role, :account_manager)
  end
end
```

Code that creates an expiry on the application's behalf, such as an import, can pass `authorize?: false` instead.

Reads stay open by default. `AshWorkflow` authorizes `:read` on the expiry resource for every actor. Add a read policy if expiries are private.

### Start the clock

`set_expiry/3` on the contract creates its expiry, or renews the one it already has:

```elixir
MyApp.Contracts.Contract.set_expiry(contract, ~U[2027-06-30 00:00:00Z], actor: current_user)
```

To give every new contract a default expiry, add `SetExpiry` with an `expires_in:` option to the contract's create action:

```elixir
create :create do
  accept [:title]
  change {MyApp.Contracts.ContractExpiry.Changes.SetExpiry, expires_in: {365, :day}}
end
```

`expires_in:` is `{count, unit}`, with a unit of `:second`, `:minute`, `:hour`, `:day` or `:week`. `expires_at` is the time the action runs plus `expires_in:`. An action that has an `:expires_at` argument uses the argument instead. An action with neither fails with an error on `expires_at`.

`SetExpiry` also works in an atomic update, so the action it is added to does not need `require_atomic? false`. It runs after the contract action, so its error fails the contract action, and on a data layer with transactions the contract change rolls back with it.

To backfill contracts that existed before the recipe, run `:set_expiry` over those without an expiry with `Ash.bulk_update/4`:

```elixir
require Ash.Query

MyApp.Contracts.Contract
|> Ash.Query.filter(not exists(expiry, true))
|> Ash.bulk_update(:set_expiry, %{expires_at: ~U[2027-06-30 00:00:00Z]},
  strategy: :stream,
  actor: current_user
)
```

`:set_expiry` declares `require_atomic? false`, so `Ash.bulk_update/4` needs `strategy: :stream`.

The actor and tenant of the contract action pass through to the expiry's `create` and `renew`, so `CanCreate` and `CanRenew` decide whether `set_expiry` succeeds. A contract action called with `authorize?: false` passes `authorize?: false` on. On a contract that uses `Ash.Policy.Authorizer`, `:set_expiry` also needs a policy of its own, and the task prints a notice saying so.

`ContractExpiry.create/3` and `ContractExpiry.renew/3` remain the lower-level calls. Use them when the code has the expiry rather than the contract:

```elixir
MyApp.Contracts.ContractExpiry.create(contract.id, ~U[2027-06-30 00:00:00Z], actor: current_user)
```

A second expiry for the same contract fails on the `:unique_subject` identity.

### Decide who may renew

`CanRenew` denies everyone, so nothing can be renewed until you change it. Replace its `match?/3`, or replace the `authorize_if` line in the expiry's policy with a built-in check:

```elixir
policies do
  policy action(:renew) do
    authorize_if actor_attribute_equals(:role, :account_manager)
  end
end
```

### Renew

`renew/3` takes the new `expires_at` and returns the expiry to `:active` from any step:

```elixir
MyApp.Contracts.ContractExpiry.renew(expiry, ~U[2028-06-30 00:00:00Z], actor: current_user)
```

`renew` does not check that the new date is in the future. Add a validation to the `:renew` action if your application needs one.

### React to expiring and expired

The task generates no notification. Add a timeout with an `action` to the `:expiring` or `:expired` step to send a reminder or revoke access, or use an Ash notifier on the expiry resource.

### Use the outcome

`expired?` on the subject is true when its expiry is in `:expired`, and false otherwise, including for a subject with no expiry. Gating a subject action on it is up to you, for example with a policy on the subject:

```elixir
policy action(:sign) do
  forbid_if expr(expired?)
  authorize_if always()
end
```

### Generate the migrations

On AshPostgres, run `mix ash.codegen add_contract_expiry` to create the expiry and transition log tables.

## Limits

`expiring_at` is a calculation, so Postgres has no index on it. The trigger for the `:active` step filters on the state and then on `expires_at` minus the notice period. The `(state, expires_at)` index AshWorkflow adds for the `:expired` timeout covers the state part of that filter only.

`expiring_at` is computed in whole seconds, so the notice deadline can fall up to a second before `expires_at` minus the notice period.

`AshWorkflow.Scheduler.due_at/2` returns `nil` for an expiry whose `expiring_at` was not loaded. Load the calculation before calling it.
