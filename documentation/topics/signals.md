# Signals

A workflow can emit `Ash.Signals` signals when its records move between steps. Other resources listen to those signals in their own `signals_in` section, so a reaction to an approval lives with the resource that reacts, and the workflow resource does not change when a reaction is added.

## Naming a signals module

The `signals` option on the `workflow` section names an application-owned module that uses `Ash.Signals`. Every `emit` in the workflow names a signal declared there, and `AshWorkflow.Verifiers.ValidateSignals` rejects a name the module does not declare.

```elixir
defmodule MyApp.Documents.Signals do
  use Ash.Signals

  signals do
    signal :document_moved do
      argument :id, :uuid, allow_nil?: false
      argument :from_state, :atom
      argument :to_state, :atom, allow_nil?: false
      argument :triggered_by, :atom, allow_nil?: false
    end

    signal :review_started do
      argument :id, :uuid, allow_nil?: false
      argument :title, :string
    end

    signal :review_finished do
      argument :id, :uuid, allow_nil?: false
      argument :to_state, :atom, allow_nil?: false
    end

    signal :document_approved do
      argument :id, :uuid, allow_nil?: false
      argument :approver_id, :uuid
      argument :outcome, :string
    end

    signal :review_overdue do
      argument :id, :uuid, allow_nil?: false
    end
  end
end
```

## Where `emit` goes

`emit` works at four levels. A signal must declare the `:after_action` phase, which is the `Ash.Signals` default.

```elixir
workflow do
  signals MyApp.Documents.Signals

  # every state change, including the initial create
  emit :document_moved

  step :review do
    # entering the step, or with `on: :exit`, leaving it
    emit :review_started
    emit :review_finished, on: :exit

    # one transition
    transition :approve do
      to :published
      emit :document_approved, fields: [approver_id: :reviewer_id], values: [outcome: "approved"]
    end

    transition :reject, to: :draft

    # a timeout's or an every's own firing
    timeout :overdue do
      fire_after {3, :days}
      action :send_overdue_notice
      emit :review_overdue
    end
  end

  step :published, terminal: true
  step :draft, terminal: true
end
```

A workflow-level `emit` fires on every state change, including the initial create, where `from_state` is `nil`. A step-level `emit` fires when a state change enters the step, or leaves it with `on: :exit`. An `emit` inside a `transition` fires when that transition runs from that step. An `emit` inside a `timeout` or an `every` fires when it does. An action timeout and an `every` firing do not change state, so they emit only their own signals, and no workflow-level or step-level signal.

A `transition`, `timeout` or `every` that contains an `emit` takes its other options inside the `do` block, as `transition :approve` does above.

## Payloads

`AshWorkflow.Changes.RecordEvent` builds each payload from the fields the signal declares, and leaves out every other field. It fills them in this order, and a later source replaces an earlier one:

1. The workflow fields `from_state`, `to_state`, `transition_name`, `triggered_by` and `occurred_at`. `transition_name` and `triggered_by` hold the same values as the transition log row.
2. Any signal field with the same name as an attribute of the resource, read from the record after the action.
3. `fields`, a keyword list of `signal_field: :attribute` pairs, or a list of attribute names that keep their names.
4. `values`, a keyword list of literal values.

## Listening

Listening needs nothing from AshWorkflow. A transition action is an ordinary update action, so a workflow resource can list one in its `signals_in` section and move its records when another resource emits a signal. Under the default inline delivery, a listener whose record is not in one of the transition's `from` states fails, and that failure rolls back the action that emitted the signal.

## Limits

- Only `:after_action` signals are emitted. A signal that declares another phase is rejected by `AshWorkflow.Verifiers.ValidateSignals`.
- A bulk action emits one signal per record. `AshWorkflow.Changes.RecordEvent` does not batch them.
- `AshWorkflow.Scheduler.Oban` and `AshWorkflow.Scheduler.Precise` run automatic steps, timeouts and `every` firings with a `nil` actor, and listeners run as the emitting action's actor. A listener's policies must allow a `nil` actor for those signals.
- A step's `on: :exit` emit and the emits inside a `transition`, `timeout` or `every` need the state the record left. An atomic update has no loaded record, so `AshWorkflow.Changes.RecordEvent` uses the transition's single `from` state, or the last transition log row. An atomic update of an action with several `from` states on a workflow without a `transition_log` does not know that state, and those emits do not fire.
- A listener that fails under inline delivery fails the action that emitted the signal, and the transaction rolls back.
