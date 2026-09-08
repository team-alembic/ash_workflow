# Demos

Runnable applications built on AshWorkflow. Each is a self-contained mix project
depending on the library by path, with its own test suite that CI runs — so a
change to the DSL that breaks a demo breaks the build.

They are chosen to exercise different parts of the extension rather than to be
re-skins of one another.

| Demo | What it is for |
|---|---|
| [`ats`](ats) | **Wait states.** A Phoenix LiveView app you can click through: conference attendees apply for a role, sit in a wait state until their own `verify_after` deadline passes, get scored by an automatic step, and are hired or rejected before an auto-reject timeout fires |
| [`document_approval`](document_approval) | **Conditional routes.** Two admins must sign off, so `:approve` is one action that deliberately does not advance the workflow the first time it is called |
| [`order_fulfilment`](order_fulfilment) | **Error handling in a long automatic chain.** Four background stages, each with an `on_error` target, two of which recover by looping backwards into the chain |
| [`subscription_dunning`](subscription_dunning) | **Timeouts.** A repeating dunning email measured from the state entry, and a one-shot suspension measured against a date stored on the record |
| [`support_ticket_sla`](support_ticket_sla) | **Routing and shared names.** Triage routes on priority; `:escalate` means different things in different steps; each queue has its own `:sla_breach` timeout |
| [`workflow_timeline`](workflow_timeline) | **State history, time travel, and undo.** An incident-response workflow with `transition_log` enabled; one page draws every incident as a Gantt-style band with a slider replaying `state_at/2`, a second runs the same workflow with `undoable?: true` and toggles between the literal and corrected readings of one log |

## Which one to read first

- New to AshWorkflow: `document_approval` — smallest surface, one clear idea.
- Wondering how failures behave: `order_fulfilment`.
- Wondering when timeouts fire: `subscription_dunning`.
- Want to see it running in a browser: `ats`.
- Wondering what the transition log buys you: `workflow_timeline`.
- Wondering how undo can rewind state without rewriting history: `workflow_timeline`, `/undo`.

## Running one

All of them need PostgreSQL. Connection details come from `POSTGRES_HOST`,
`POSTGRES_PORT`, `POSTGRES_USER` and `POSTGRES_PASSWORD`, defaulting to
`postgres:postgres@localhost:5432`.

```bash
cd demos/document_approval
mix deps.get
mix test
```

`mix test` creates and migrates the demo's database for you. Each demo uses its
own database, so they do not interfere with each other or with the library's own
test suite.

## Why the tests matter

The headless demos drive real Oban against real Postgres rather than asserting
on generated DSL, which is what makes them useful as a safety net. Several
library bugs were found by writing them:

- `on_error` was forbidden by the generated policies on any resource with an
  authorizer, so failing steps silently stayed put
- timeout names were not scoped by step, so "one SLA per queue" would not compile
- step policies on a transition name shared between steps blocked each other,
  with no indication why

Each demo's test suite uses a `run_workflow_triggers/1` helper that schedules and
drains the triggers, so tests assert on what Oban actually did rather than on
what was configured.
