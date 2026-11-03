# Design: on_signal

Status: implemented. Builds on `emit` and the `signals` option from #148.

## The problem

`emit` lets a workflow tell the rest of the application what happened. The reverse is missing: a step cannot say "a signal from elsewhere moves this record on". Issue #61 describes the gap. Today a step that reacts to an outside event is written as a manual transition plus a lookup that the caller writes. The caller finds the record by an external id and calls the transition. Nothing in the workflow names the event, nothing checks the correlation key, and nothing records why the record moved.

Ash signals already cover most of the receiving side. A resource's `signals_in` section runs an update action on the records that a read action and `get_by` select for each signal. A transition is an update action. A signal that moves a record is therefore a listener whose action is a transition and whose read action only selects records in the right step. This design is about which part of that AshWorkflow generates, and what the DSL looks like.

## The proposal

`on_signal` is a step entity. It names a signal, says how to find the record from the signal, and says what happens when the signal arrives. It sits beside the step's other exits rather than replacing them:

```elixir
workflow do
  signals MyApp.Orders.OrderSignals

  step :awaiting_payment do
    transition :mark_paid, to: :fulfilling

    on_signal :payment_settled do
      filter expr(id == ^signal(:order_id))
      transition_to :fulfilling
    end

    timeout :payment_expired do
      fire_after {3, :days}
      transition_to :cancelled
    end
  end
end
```

The signal comes from the workflow's own `signals` module unless the handler names another one with `from`.

The step above has three exits. A person with the right policy calls `:mark_paid`. The payments domain emits `:payment_settled`. Otherwise the clock moves the record to `:cancelled` after three days. Whichever happens first wins, and the other two find the record no longer in the step.

`on_signal` works on any step that is not terminal. A manual step keeps its transitions. A wait state, which today must exit through a `timeout`, can also exit through an `on_signal`. A step whose only exits are `on_signal`, with or without a `timeout`, is a wait state on an outside event, which is the case #61 asks for.

### Why `on_signal`

`on_signal` reads as "when this signal arrives". It does not claim the step is idle. The name also groups with `on_success` and `on_error`, which say what happens when the step's own action finishes. `on_signal` says what happens when something outside the step finishes. `wait_for` was the first name, from #61. It describes only the wait-state case and reads wrongly on a manual step that a person can also move.

### Selecting the record

A listener on an update action selects its records with a read action. Ash's listener sets that read action's arguments from signal fields with `args`, and offers `get_by` as an equality shorthand. `on_signal` writes the read action for you. `filter` is the read action's filter, and `^signal(:field)` stands for a field of the incoming signal:

```elixir
on_signal :payment_settled do
  filter expr(id == ^signal(:order_id))
  transition_to :fulfilling
end

on_signal :refund_issued do
  filter expr(customer.email == ^signal(:email) and total == ^signal(:amount))
  transition_to :refunded
end
```

`signal/1` returns the same template as `arg/1`. From that one `filter`, AshWorkflow generates three things:

- a read action named `:__signal_<step>_<signal>_read`, whose filter is the `filter` combined with `state == :<step>`
- an argument on that read action for each field passed to `signal/1`, typed from the signal's declaration
- `args: [...]` on the listener, naming those same fields, so Ash sets the arguments from each signal

Because it is an ordinary read filter, it can follow relationships, use `exists/2`, and call calculations, which `get_by` cannot. It runs in the data layer.

A filter can match more than one record. Each matching record in the step moves, so a `:batch_shipped` signal can move every order in that batch. That is the intended behaviour, not something to guard against.

`read_action` names a read action of your own instead of `filter`. AshWorkflow then sets its arguments from signal fields of the same name, and still adds the state filter. That covers a selection that needs a preparation, or that other code already uses.

The cost of `filter` over `get_by` is batching. Ash runs one read for each distinct set of read arguments, whereas `get_by` folds a batch of signals into one query with `or`. That only matters when a listener receives many signals at once, which inline delivery does for a bulk action that emits.

### Options

| Option | Meaning |
| --- | --- |
| name (positional) | The signal. |
| `from` | Optional. The `Ash.Signals` module that declares the signal. Defaults to the workflow's `signals` module. |
| `filter` | An expression that selects the records to move, with `^signal(:field)` for signal fields. Mutually exclusive with `read_action`. |
| `read_action` | A read action of your own that selects the records. Its arguments are set from signal fields of the same name. |
| `transition_to` | The step to move to. Mutually exclusive with `action`, as on `timeout`. |
| `action` | An update action to run without leaving the step, for a signal that changes data but not state. |
| `inputs` | Action inputs taken from signal fields, passed to Ash's listener unchanged. For example, `inputs: [paid_at: :settled_at]`. |
| `delivery` | Passed to Ash's listener unchanged. Defaults to `Ash.Signals.Delivery.Inline`. |

The entity can hold `emit`, like `transition` and `timeout`, so a received signal can be re-emitted in the workflow's own vocabulary.

### What it generates

- **A transition action** named `:__signal_<step>_<signal>`, with `triggered_by: :signal` and the signal's name as `transition_name`. This is the same pattern as a transition timeout's `:__timeout_<step>_<name>` action. `:signal` is a new `triggered_by` value. It covers part of what #72 asks for with `:external`.
- **A read action** that applies `filter` and selects only records whose state is the step. Ash's listener treats an empty selection as "handled, nothing happens". A signal for a record that has already left the step, because a person or a timeout moved it first, is therefore ignored. Without the filter, AshStateMachine would reject the transition, and under inline delivery that rejection rolls back the emitter.
- **A `signals_in` listener** named `:<step>_<signal>` that joins the two: `on :payment_settled, :awaiting_payment_payment_settled, action: ..., read_action: ..., args: [:order_id]`. AshWorkflow adds it to the resource's `signals_in` section from a transformer, so the resource needs no `signals_in` section of its own.
- **A policy** on the generated transition and read actions: `authorize_if signal_in(MyApp.Orders.OrderSignals, :payment_settled)`. The listener runs as the emitting actor, who usually may not move the workflow directly. `AshWorkflow.Transformers.AddPolicies` already scopes policies to generated actions. A handler with `action` runs the user's own update action, which gets no generated policy, so the user authorizes it.
- **One event per run:** a handler with `action` appends `RecordEvent` to that action. Handlers that share an action share one `RecordEvent`. `AshWorkflow.Verifiers.ValidateOnSignal` rejects an action that a `timeout` or `every` also names, since that action would log each run twice.

### What changes elsewhere

- **Wait states:** `AshWorkflow.Verifiers.ValidateWorkflow` accepts an `on_signal` with `transition_to` as an exit, alongside a `timeout` with `transition_to`.
- **Verifier:** a new check that the signal exists in its module, that each `signal/1` names a field the signal declares, that a `read_action`'s arguments are all signal fields, and that `transition_to` names a step.
- **`AshWorkflow.Info`:** `on_signals/1` and `on_signals/2` list the handlers, and `workflow_graph/1` gives each step's handlers under `:on_signals`.
- **Charts:** an edge labelled `📨` and the signal's name, and a `📨` note for a handler with `action`.
- **Transition log:** the row records `triggered_by: :signal`. Recording the received `signal_id` would let a log row point at the message that caused it. That needs a nilable column, so it is left open.

## Composing workflows

A signal emitted by one workflow's `emit` can move another workflow through `on_signal`. A parent workflow then follows a child with no shared code and no callback:

```elixir
# MyApp.Shipping.Shipment
step :delivered, terminal: true do
  emit :shipment_delivered
end

# MyApp.Orders.Order
step :awaiting_delivery do
  transition :mark_delivered, to: :completed

  on_signal :shipment_delivered do
    from MyApp.Shipping.ShipmentSignals
    filter expr(id == ^signal(:order_id))
    transition_to :completed
  end
end
```

This is the case that makes `on_signal` more than a shorthand for Ash's own `signals_in`. The order does not know how a shipment works. The shipment does not know that orders exist. Support staff can still mark the order delivered by hand. The handler names `from` here because the signal belongs to the shipment's module, not the order's.

## Alternatives

### 1. A signal option on `transition`

The signal becomes one more way to call an existing transition:

```elixir
transition :mark_paid do
  to :fulfilling
  on_signal :payment_settled, filter: expr(id == ^signal(:order_id))
end
```

A person and a signal then fire the same action, so the transition's routes, `accept` and `emit` apply to both. Two things count against it. A step whose only exit is a signal must still declare a transition that anyone with the right policy can call. The shared action also has one `RecordEvent` with `triggered_by: :manual` in its options, so the log could not tell the two apart without passing the trigger through the changeset context.

### 2. Document the hand-written `signals_in`

The application declares the listener, a read action filtered by state, and the policy. That works today with no AshWorkflow change. Nothing then names the signal in the workflow, the diagram shows no edge, and the state filter is easy to forget. Forgetting the filter rolls back the emitter whenever the signal arrives for a record in another step.

### 3. A workflow-level `signals_in` block

This mirrors Ash's syntax inside `workflow`, with each `on` naming a step. Every handler is then declared away from the step it belongs to, which is the opposite of how `timeout` reads.

### Ranking

The ranking is the proposal, then alternative 1, then 2. Alternative 1 suits a transition whose routes and `accept` should apply however it was triggered, and it could be added later. The strongest objection to the proposal is that it adds a fourth way to leave a step, after manual transitions, `on_success` and timeouts. The answer is that it has the same shape as `timeout`, and that the generated pieces are the ones a careful application would write by hand.

## Open questions

- **Early signals:** a signal that arrives before the record reaches the step selects nothing and is lost. BPMN handles this with message buffering. A per-workflow inbox resource that `on_signal` checks on step entry would cover it, but it is a separate feature. The first version documents the race.
- **Delivery default:** inline delivery runs the transition inside the emitter's transaction, so a failing transition rolls back the payment that emitted the signal. A queued delivery would decouple them, but Ash ships only `Ash.Signals.Delivery.Inline`. Should AshWorkflow default to inline and document the coupling, or wait for an AshOban delivery?
- **Re-emitting signal fields:** an `emit` nested in `on_signal` could copy fields from the received signal, as in `emit :order_paid, values: [paid_at: signal(:settled_at)]`. Without that, the handler first stores the field on the record with `inputs: [paid_at: :settled_at]`, and the `emit` reads it from there. The first version leaves this out, because the `inputs` route already works.
- **Reusing a transition:** should `on_signal` also accept `transition: :mark_paid`, running that transition's action instead of generating one? That is alternative 1 expressed from the step side, and it has the same `triggered_by` problem.
