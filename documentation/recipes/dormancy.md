# Dormancy

`mix ash_workflow.gen.dormancy` adds a dormancy workflow to a resource. Each record carries a `last_activity_at` that your application moves whenever the record is used. A record nobody uses for a while moves to `:dormant`, optionally moves on to `:archived`, and returns to `:active` when it is reactivated.

## The command

```bash
mix ash_workflow.gen.dormancy MyApp.Accounts.Account --dormant-after 90d --archive-after 180d
```

| Option | Default | Effect |
|---|---|---|
| `--dormant-after` | required | Moves a dormancy to `:dormant` once `last_activity_at` is this old. Accepts `10s`, `30m`, `12h`, `2d` and `2w`. |
| `--archive-after` | none | Moves a dormancy to `:archived` once it has been `:dormant` this long. Without it, no `:archived` step is generated. |
| `--module` | `<Subject>Dormancy` | Name of the generated dormancy resource. |
| `--domain` | the subject's domain | Domain for a subject the task creates. Required only when the subject does not exist. |
| `--transition-log` | `true` | Also runs `mix ash_workflow.gen.transition_log` for the dormancy resource. Pass `--no-transition-log` to skip it. |

When the subject does not exist, the task creates it with `mix ash.gen.resource`, using the data layer of the first ETS or Postgres resource in `--domain`. When no resource there uses ETS or Postgres, the task stops with an issue and writes nothing. Create the subject resource first, or pass a `--domain` that has one. Running the task again on the same subject changes nothing.

## What it generates

For the command above, the task writes two modules and edits the subject:

- `MyApp.Accounts.AccountDormancy` runs the workflow. It belongs to the account and holds `last_activity_at`. An identity on `subject_id` allows one dormancy per account.
- `MyApp.Accounts.AccountDormancy.Checks.CanReactivate` decides who may reactivate. It denies everyone as generated.
- `MyApp.Accounts.Account` gains `has_one :dormancy` and a `dormant?` calculation. The task adds no change, argument or policy to the subject's actions.

The dormancy is a separate resource rather than a `workflow` block on the subject, so a subject that already runs a workflow keeps it.

## The workflow

```mermaid
stateDiagram-v2
  [*] --> active
  active --> dormant: last_activity_at older than dormant_after
  dormant --> archived: dormant for archive_after
  dormant --> active: reactivate
  archived --> active: reactivate
```

```elixir
workflow do
  step :active do
    timeout :dormant, fire_after: {90, :days}, field: :last_activity_at, transition_to: :dormant
  end

  step :dormant do
    transition :reactivate, to: :active

    timeout :archived, fire_after: {180, :days}, transition_to: :archived
  end

  step :archived do
    transition :reactivate, to: :active
  end
end
```

Without `--archive-after`, there is no `:archived` step. A dormant record then stays dormant until it is reactivated.

The `:dormant` deadline is measured from `last_activity_at`. Each call to `record_activity` writes the current time to it, so a record in use never reaches the deadline.

The `:archived` deadline is measured from `state_entered_at`, the moment the record became dormant. Activity on a dormant record does not move it. A record that is used while dormant, but never reactivated, still archives on time.

`reactivate` writes the current time to `last_activity_at` as well as returning the record to `:active`. Without that, a reactivated record would go dormant again on the next scheduler pass.

`:archived` is not terminal. An archived record stays archived until it is reactivated.

## What your application does next

### Create the dormancy

Call `create/2` wherever a subject starts to be tracked, such as the subject's create action, a sign-up step or an import:

```elixir
MyApp.Accounts.AccountDormancy.create(account.id)
```

`last_activity_at` defaults to the time of creation. An import can pass the subject's real last use instead:

```elixir
MyApp.Accounts.AccountDormancy.create(account.id, %{last_activity_at: last_seen_at})
```

The generated `:create` action has no policy. Add one to the dormancy resource if your application restricts who can create a dormancy. A second dormancy for the same account fails on the `:unique_subject` identity.

### Record activity

Call `record_activity/2` whenever the subject is used, such as on a sign-in, an API request or an edit:

```elixir
MyApp.Accounts.AccountDormancy.record_activity(dormancy)
```

`record_activity` changes no state and is allowed for every caller. Replace `authorize_if always()` in its policy if you expose it to users directly.

### Decide who may reactivate

`CanReactivate` denies everyone, so nothing can be reactivated until you change it. Replace its `match?/3`, or replace the `authorize_if` line in the dormancy's policy with a built-in check:

```elixir
policies do
  policy action(:reactivate) do
    authorize_if actor_attribute_equals(:role, :support)
  end
end
```

### Reactivate

`reactivate/2` returns a dormant or archived dormancy to `:active`:

```elixir
MyApp.Accounts.AccountDormancy.reactivate(dormancy, actor: current_user)
```

Activity on a dormant record does not reactivate it. To wake an account when its owner signs in, call `reactivate` from the sign-in with an actor `CanReactivate` permits.

### React to dormant and archived

The task generates no notification. Add a timeout with an `action` to the `:dormant` or `:archived` step to send a reminder or revoke access, or use an Ash notifier on the dormancy resource.

### Use the outcome

`dormant?` on the subject is true when its dormancy is in `:dormant` or `:archived`. Gating a subject action on it is up to you, for example with a policy on the subject:

```elixir
policy action(:sign_in) do
  forbid_if expr(dormant?)
  authorize_if always()
end
```

Read `dormancy.state` to tell a dormant subject from an archived one.

### Generate the migrations

On AshPostgres, run `mix ash.codegen add_account_dormancy` to create the dormancy and transition log tables.

## Limits

`record_activity` writes the dormancy row on every call. An application that calls it on every request writes that row on every request. To reduce writes, call it only when `last_activity_at` is older than some threshold you choose.
