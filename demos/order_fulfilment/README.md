# Order fulfilment

An order moving through payment, stock reservation, packing and shipping, where
every stage is background work that can fail.

This is the demo for **error handling in a long automatic chain**. Each
automatic step declares `on_error`, so a failure lands the order in a state that
names the problem instead of leaving it stuck mid-flight:

```elixir
step :charging_card do
  action :charge_card
  on_success :reserving_stock
  on_error :payment_failed
end
```

Two of those failure states are recoverable, and their recovery transitions loop
*backwards* into the chain — so the step that failed runs again rather than being
skipped.

## The flow

```
placed ──▶ charging_card ──▶ reserving_stock ──▶ packing ──▶ shipping ──▶ shipped
                │                  │                            │
                │                  ╰──▶ backordered ──(restocked)──╮
                │                            │                     │
                │                            ╰─(cancel)──▶ cancelled
                │
                ╰──▶ payment_failed ──(retry_payment)──▶ charging_card
                           │
                           ╰─ 3 days ──▶ cancelled
```

## What it demonstrates

| Feature | Where |
|---|---|
| `on_error` on every automatic step | no failure leaves an order stuck |
| Loopback transitions | `retry_payment` → `:charging_card`, `restocked` → `:reserving_stock`, `retry_shipping` → `:shipping` |
| One transition name shared across steps | `:cancel` is declared on four different failure states and merges into a single action that routes by current state |
| `accept` on a transition | `:cancel` takes a `cancellation_reason` |
| Custom Oban queue | `queue :fulfilment` |
| Repeating timeout | chasing the supplier while backordered |
| Transition timeout | abandoning an unfixed payment after three days |

## A note on transactions

A failing step's own writes roll back with it. `charge_card` bumps a
`payment_attempts` counter *and* fails on a declined card — and the counter
stays at zero, because the whole action was one transaction. Only the state
change made by the `on_error` handler survives. If you need a durable record of
attempts, write it from the error handler, not from the step that failed.

The test suite asserts this directly, so the behaviour is visible rather than
surprising.

## Running it

Needs PostgreSQL. Connection details come from `POSTGRES_HOST`, `POSTGRES_PORT`,
`POSTGRES_USER` and `POSTGRES_PASSWORD`, defaulting to
`postgres:postgres@localhost:5432`.

```bash
mix deps.get
mix test
```
