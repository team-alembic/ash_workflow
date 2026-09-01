# Design: workflow history and time-travel

A working document for the transition-log feature. It records the decision and
the reasoning behind it; the user-facing half becomes
`documentation/topics/workflow-history.md` when the work lands.

## The problem

A workflow resource persists exactly two pieces of state: `state`, managed by
`ash_state_machine`, and `state_entered_at`, added by
`AshWorkflow.Transformers.AddAttributes`. Every transition overwrites
`state_entered_at`. Nothing else is kept.

So the library cannot answer either of these:

- **Point query.** What state was this workflow in at 3pm last Tuesday?
- **Aggregate query.** How many workflows were sitting in `:awaiting_review` at
  the end of last month?

There is a second, quieter problem. `state_entered_at` does not mean what its
name says. Repeating timeouts reset it *without a state change*, because that
reset is how the repeat re-arms: the generated Oban trigger filters on
`field <= ago(duration)`, so moving the timestamp forward is what schedules the
next firing. A workflow that has been in `:awaiting_review` for nine days but
sends a reminder every two will report a `state_entered_at` of two days ago.

The field is a **timer anchor**, not a history fact. The name has been lying.

## What we are building

An opt-in transition log: a resource that records one row per workflow event,
with the workflow resource keeping a `has_many` to it. The log becomes the
source of truth for history, and `state_entered_at` becomes a projection of it.

```elixir
workflow do
  transition_log MyApp.TicketTransition

  step :triage do
    transition :escalate, to: :urgent_queue
  end
end
```

```elixir
Ticket.state_at(ticket, ~U[2026-08-01 09:00:00Z])
#=> :awaiting_review

Ticket.history(ticket)
#=> [%TicketTransition{from_state: nil, to_state: :triage, triggered_by: :initial}, ...]
```

## Decisions

### The log records every workflow event, not only state changes

A repeat that fires a reminder writes a row with `from_state == to_state` and
`triggered_by: :timeout`. It is not a transition, but it *is* something that
happened, and today the record of it is destroyed.

This matters for two reasons. It makes the history complete — "reminder sent
three times, then escalated" is visible. And it is what allows the timer anchor
to be derived from the log at all: if repeats were excluded, the log could not
reproduce the anchor's value.

The cost is that "when did we enter this state" and "when did the timer last
reset" become two different questions. They are answered by two calculations:

| Value | Definition |
|---|---|
| `state_entered_at` | `occurred_at` of the most recent row, any row |
| `entered_current_state_at` | `occurred_at` of the most recent row where `from_state != to_state` |

The first reproduces today's behaviour exactly. The second is the honest answer
the library has never been able to give.

### `state_entered_at` stays a real column, written through from the log

It is tempting to delete the attribute and derive it. We are not going to,
because of where it is read: the generated Oban triggers filter on it, and those
schedulers run on every tick of `check_interval` — every minute by default,
once per automatic step and once per timeout, across the whole table.

As a column that is a plain indexed comparison. As a `first` aggregate over a
`has_many` it becomes a correlated subquery per row on every tick. That is a
material regression on a large table in exchange for no semantic gain, since the
column and the aggregate would hold the same value by construction.

So: **derived in principle, denormalised in practice.** The log is the truth;
the column is a write-through cache of it, maintained by the same change that
appends the row. Nothing else may write it.

### One change module replaces five copy-pasted call sites

`AddActions` currently injects `set_attribute(:state_entered_at, ...)` at five
places, one per kind of workflow event:

| `add_actions.ex` | Event | `triggered_by` |
|---|---|---|
| line 111 | manual transition | `:manual` |
| line 198 | automatic step success | `:automatic` |
| line 231 | `on_error` path | `:error_path` |
| line 270 | timeout that transitions | `:timeout` |
| line 301 | repeating timeout action | `:timeout` |

All five are replaced by a single `AshWorkflow.Changes.RecordEvent` carrying the
`triggered_by` for that site. It updates the anchor, and appends a log row when
a log resource is configured. The five-way duplication was already a latent
inconsistency — line 301 is the odd one out, with no `transition_state` beside
it — and collapsing it is worth doing regardless of this feature.

Note that the codepath does **not** fork on whether logging is enabled. The
change is always injected; the log append is one conditional at the leaf.

A sixth event has no call site today: the `:initial` row. Workflows are started
through the user's own create action, so this needs a resource-global
`change ..., on: [:create]` rather than a hook on a generated action.

### The log resource is user-owned and scaffolded, not generated

A transformer cannot generate an Ash resource cleanly. It would have to register
the module in the user's domain — which Ash 3 validates in both directions
unless the domain opts into `allow_unregistered?` — and on AshPostgres the table
would need a migration that `mix ash.codegen` never sees.

`Module.create` of a *worker* is fine and AshOban does it. A resource is not.

So the DSL names the module and an igniter task scaffolds it:

```bash
mix ash_workflow.gen.transition_log MyApp.Ticket
```

A verifier checks the required attributes exist and the data layer matches. The
user owns the file, so extra columns are theirs to add. This follows AshOban's
`worker_module_name` precedent: name the module, don't conjure it.

It also means the feature cannot default to on — there is no module to point at
until the generator has run.

### Actor capture is configured, AshPaperTrail-style

```elixir
transition_log MyApp.TicketTransition do
  belongs_to_actor :user, MyApp.Accounts.User
end
```

Rather than the library guessing an actor type. The actor is available as
`context.actor` in the change.

## Schema

Required attributes on the log resource:

| Attribute | Type | Notes |
|---|---|---|
| `workflow_id` | `belongs_to` | to the workflow resource |
| `from_state` | `:atom` | `nil` on the `:initial` row |
| `to_state` | `:atom` | equal to `from_state` for repeats |
| `transition_name` | `:atom` | the action that ran |
| `occurred_at` | `:utc_datetime_usec` | |
| `triggered_by` | `:atom` | `:initial \| :manual \| :automatic \| :timeout \| :error_path` |

Indexed on `(workflow_id, occurred_at DESC)`.

## Queries

The point query resolves in Elixir and is portable across data layers:

```elixir
Ticket.state_at(ticket, at)
```

The aggregate query is latest-row-per-workflow-before-`Y`, which Ash's query
language cannot express portably. It is documented rather than shipped as an
API:

```sql
SELECT DISTINCT ON (workflow_id) workflow_id, to_state
FROM ticket_transitions
WHERE occurred_at <= $1
ORDER BY workflow_id, occurred_at DESC;
```

## Correctness

**Transactionality.** The row is written in an `after_action` hook, so on
Postgres the state update and the log row commit or roll back together. ETS has
no transactions; a crash between the two can drop a row. Documented, not solved.

**Atomicity.** Injecting a hook-bearing change interacts with `require_atomic?`.
Conditional transitions already set `require_atomic? false`
(`add_actions.ex:124`); plain ones do not. `RecordEvent` needs an `atomic/3`, or
the generated actions need `require_atomic? false` when logging is on. This is
the likeliest source of bugs in the implementation and needs a direct test.

**Backfill.** History before the feature was enabled is gone and cannot be
recovered. Enabling the log seeds one approximate `:initial` row per existing
record from its current `state` and `state_entered_at`.

## What this is not

Not an audit trail. The log records workflow events, not attribute changes and
not who edited what. AshPaperTrail remains the right tool for that, and the two
compose — `bpmn-comparison.md` should be updated to describe both rather than
saying audit is not built in.

Not event sourcing. State remains a column on the workflow row; the log
describes how it got there. Replay is out of scope.

## Rejected alternatives

**History column on the workflow row** (array of embeds, or SCD-2 rows). The
aggregate query becomes bad SQL, rows grow unboundedly, every transition
rewrites the whole column, and there is nowhere to hang an actor FK or an index.
SCD-2 additionally breaks the one-row-per-workflow assumption that the Oban
triggers' `where state == ...` clauses depend on.

**AshPaperTrail as the mechanism.** Answers "who changed what attribute", not
"what was the state timeline". Whether `state` is a column or buried in a JSONB
`changes` map depends on the user's `change_tracking_mode`, so the library
cannot query it reliably; the versions table is far noisier; and every repeat
reset would produce a junk version row. It is also not currently a dependency.

**ash_events.** Logs at action granularity with replay semantics that fight
ash_oban's side effects. A bigger hammer and a new dependency. Worth a "see
also".

**Deriving from Oban job history.** Manual transitions never touch Oban, and
Oban prunes its jobs.

## Open questions

- Whether `transition_log` is a plain option or a nested section from the start.
  The `belongs_to_actor` decision forces a section, so: a section.
- Naming: `transition_log` vs `history`; `triggered_by` vs `source`.
- Whether the `:initial` row is a distinct `triggered_by` value or inferred from
  a `nil` `from_state`. Both is redundant.

## Checks this must pass

`test/documentation_drift_test.exs` fails the build if a new DSL option is not
mentioned in `usage-rules.md`. New topic pages must be registered in `mix.exs`
`extras`. Generation changes need tests at both levels — generated DSL *and* a
Postgres test that actually runs Oban, per `CONTRIBUTING.md`.
