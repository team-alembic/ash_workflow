# Support ticket SLA

A support ticket is triaged, worked, and escalated if it misses its SLA.

This is the demo for **one transition leading to different places depending on
the record**, and for **the same transition name meaning different things in
different steps**.

## Triage routes on the ticket, not the caller

```elixir
transition :triage do
  route :urgent_queue,   when: expr(priority == :urgent)
  route :standard_queue, when: expr(priority == :normal)
  route :backlog,        when: expr(priority == :low)
end
```

The caller just calls `:triage`. Where the ticket lands is decided from the
ticket itself.

## `:escalate` means two different things

It is declared on three steps. From a queue it goes to a manager; from the
backlog it is a promotion into the standard queue. AshWorkflow merges those into
one `:escalate` action that routes by the ticket's current state, so callers
never need to know which step a ticket is in.

## Each queue has its own SLA

```elixir
step :urgent_queue do
  timeout :sla_breach, fire_after: {1, :hours}, transition_to: :escalated
end

step :standard_queue do
  timeout :sla_breach, fire_after: {2, :days}, transition_to: :escalated
end
```

Both are called `:sla_breach`. Timeout names are scoped to their step, so this
is the natural model rather than a name collision.

## The flow

```
triaging ──(triage)──▶ urgent_queue   ── 1 hour  ─▶ escalated
    │                  standard_queue ── 2 days  ─▶ escalated
    │                  backlog        ──(escalate)▶ standard_queue
    │
    ╰─ 4 hours ─▶ escalated ──(manager_resolve)──▶ resolved
                       ╰─(reassign)──▶ standard_queue
```

## What it demonstrates

| Feature | Where |
|---|---|
| Conditional routes | `:triage` picking a queue from `priority` |
| One transition name, several steps, different targets | `:escalate` |
| Same timeout name on different steps | `:sla_breach` per queue |
| Step-level policies | agents work queues; only managers close escalations |
| Action timeout vs transition timeout | the urgent-queue warning vs the breach |
| Repeating timeout | re-flagging stale backlog tickets |

## Why `manager_resolve` rather than `resolve`

Steps that share a transition name merge into a single action, and each step's
`policy` is applied to that action. Ash requires every applicable policy to
pass, so an agents-only policy and a managers-only policy on the same action
would block each other. AshWorkflow rejects that at compile time, so the
escalated step uses a distinct transition name — see the
[authorization usage rules](../../usage-rules/authorization.md).

## Running it

Needs PostgreSQL. Connection details come from `POSTGRES_HOST`, `POSTGRES_PORT`,
`POSTGRES_USER` and `POSTGRES_PASSWORD`, defaulting to
`postgres:postgres@localhost:5432`.

```bash
mix deps.get
mix test
```
