# Subscription dunning

A subscription falls into arrears, gets chased for payment, and is eventually
cancelled if nobody pays.

This is the demo for **timeouts**, and specifically for two kinds of deadline
that look alike in the DSL and behave quite differently.

## Repeating: measured from when the state was entered

```elixir
timeout :dunning_email, after: {3, :days}, action: :send_dunning_email, repeat: true
```

Fires every three days for as long as the subscription stays in
`:grace_period`. It works by resetting `state_entered_at` each time it fires,
which is why the clock has to move on again before the next send — visible
directly in the tests.

## One-shot: measured against a date on the record

```elixir
timeout :grace_expired,
  after: {1, :seconds},
  field: :grace_period_ends_at,
  transition_to: :suspended
```

The deadline is a column, set by whatever marked the payment as failed. Two
customers in the same state can therefore have different deadlines, which a
"N days since entering this state" timeout cannot express. Durations must be
positive, so `{1, :seconds}` is the idiom for "as soon as this date has passed".

The two cannot be combined, and AshWorkflow rejects it at compile time: a
repeating timeout resets its field to now, and resetting `grace_period_ends_at`
would claim the grace period restarted when it did not.

## The flow

```
active ──(payment_failed)──▶ grace_period ──(payment_received)──▶ active
                                  │                                 ▲
                                  │  every 3 days: dunning email     │
                                  │                                 │
                                  ╰─ grace ends ──▶ suspended ──────╯
                                                        │  (payment_received)
                                                        ╰─ 30 days ──▶ cancelled
```

## What it demonstrates

| Feature | Where |
|---|---|
| `repeat: true` | the dunning email, firing once per interval |
| `field:` on a timeout | the per-customer grace deadline |
| One-shot action timeout | the final notice, which does not repeat |
| Transition timeout | giving up after thirty days suspended |
| Shared transition names | `:payment_received` and `:cancel` are declared on both arrears states |
| Tuned `check_interval` | dunning moves once a day, so the resource polls hourly rather than every minute |

## Running it

Needs PostgreSQL. Connection details come from `POSTGRES_HOST`, `POSTGRES_PORT`,
`POSTGRES_USER` and `POSTGRES_PASSWORD`, defaulting to
`postgres:postgres@localhost:5432`.

```bash
mix deps.get
mix test
```
