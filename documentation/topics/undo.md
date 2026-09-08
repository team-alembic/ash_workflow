# Undo

Undo rewinds a workflow record to the state it occupied before its most recent
state change. It is built entirely on the [transition
log](workflow-history.md) — undo has nothing to rewind to without one.

## Enabling it

Undo is opt-in twice. The `undo` block turns the feature on; `undoable?: true`
marks the individual transitions that may be rewound.

```elixir
workflow do
  transition_log MyApp.IncidentTransition do
    belongs_to_actor :user, MyApp.Accounts.User
  end

  undo do
    within {30, :minutes}
    same_actor? true
  end

  step :triage do
    transition :escalate, to: :responding, undoable?: true
    transition :close, to: :closed
  end

  step :responding do
    transition :resolve, to: :resolved, undoable?: true
  end

  step :closed, terminal: true
  step :resolved, terminal: true
end
```

Here `escalate` and `resolve` can be taken back; `close` cannot. Nothing is
undoable by default, on purpose — see [What undo does not
do](#what-undo-does-not-do).

If your transition log predates undo, regenerate it — `mix
ash_workflow.gen.transition_log` now emits the self-referencing `undoes`
relationship that undo rows point through, and a compile-time verifier requires
it.

## Using it

```elixir
incident = MyApp.Incident.escalate!(incident, actor: user)
incident.state
#=> :responding

{:ok, incident} = MyApp.Incident.undo(incident, actor: user)
incident.state
#=> :triage
```

Two helpers answer the same question without writing, for driving UI:

```elixir
MyApp.Incident.undoable?(incident, user)   #=> true
MyApp.Incident.undo_target(incident, user) #=> :triage
```

`undoable?/2` asks whether there is anything to undo. Ash's code interface
separately generates `can_undo?/2`, which asks whether the actor is
*authorized* to call the action — a different question, and both are worth
checking before showing a button.

## An undo is a new row, not an erasure

This is the design decision everything else follows from. Undoing `escalate`
does not touch the row that recorded it. It appends a row carrying
`triggered_by: :undo` and an `undoes_id` pointing back at what it reverses:

| # | from | to | transition | triggered_by | undoes |
|---|---|---|---|---|---|
| 1 | — | `:triage` | `:create` | `:initial` | |
| 2 | `:triage` | `:responding` | `:escalate` | `:manual` | |
| 3 | `:responding` | `:triage` | `:escalate` | `:undo` | 2 |

So undo moves *backward in state* and *forward in the log*. The record really
was `:responding` for a while — perhaps long enough for a notification to go
out — and the log still says so. What the undo row records is that the decision
was **superseded**, not that it never happened.

Keeping both facts means both readings stay available from the same rows:

```elixir
# What actually happened.
MyApp.Incident.history(incident)
#=> rows 1, 2, 3

# What stands after corrections.
MyApp.Incident.history(incident, effective: true)
#=> rows 1, 3

MyApp.Incident.state_at(incident, during_the_escalation)
#=> :responding

MyApp.Incident.state_at(incident, during_the_escalation, effective: true)
#=> :triage
```

Use the literal reading for audit, and for explaining why a side effect
happened. Use the effective reading for timeline UIs, where a briefly-occupied
state usually reads as noise. Had undo instead flagged row 2 as undone, only
the second reading would exist and the first would be unrecoverable — see
`documentation/design/workflow-undo.md` for why that trade was refused.

### Redo

Undoing an undo re-applies the transition, and needs no extra API:

```elixir
{:ok, incident} = MyApp.Incident.undo(incident, actor: user)  # back to :triage
{:ok, incident} = MyApp.Incident.undo(incident, actor: user)  # forward to :responding again
```

Row 3 is now itself superseded by row 4, so the effective history shows the
redo standing. The rule — "drop every row some other row points at" — handles
chains of any length without a special case.

## What can be undone

Only the most recent **state change**, and only when it came from a transition
marked `undoable?: true`.

Rows where `from_state == to_state` are skipped while looking for that change.
A repeating timeout writes one every time it re-arms; it moved nothing, so a
pending reminder does not block undo of the transition before it.

Everything else is refused, with a reason on
`AshWorkflow.Errors.UndoNotPermitted`:

| Reason | When |
|---|---|
| `:not_undoable` | The last state change was not an undoable transition. Automatic steps, timeouts, error paths and the initial row all land here. |
| `:no_history` | The record has not transitioned yet. |
| `:window_expired` | The transition is older than `within`. |
| `:different_actor` | `same_actor?` is set and the actor differs. |
| `:no_actor` | `same_actor?` is set and either side has no actor. |
| `:undo_not_enabled` | The workflow has no `undo` block. |

### Automatic steps close the window

A transition whose target is an *automatic* step is undoable only until that
step runs. Once its Oban trigger fires, the head of the log is the automatic
step's own row — which is not an undoable transition — and undo refuses with
`:not_undoable`.

This is intended: by then the automatic step's action has already done whatever
it does. But it means an undo button on a transition into an automatic step has
a lifetime measured by your `check_interval`, and is worth designing around
rather than discovering.

## Authorization

Step policies do not apply to undo. An undo spans two states, and which step it
rewinds into is known only once the log has been read, so there is no step
whose policy could correctly govern it. Give the action its own check:

```elixir
undo do
  policy actor_attribute_equals(:role, :supervisor)
end
```

Without a `policy`, the generated `undo` action falls under the extension's
default-allow, like every other generated action. `same_actor?` is a separate,
narrower control: it constrains *whose* transition you may undo, not who may
call undo at all.

## What undo does not do

**It does not restore attributes.** The log records states, not the values a
transition with `accept` wrote. Undoing a transition that set `priority: :high`
leaves `priority` as `:high`.

**It does not compensate side effects.** An email sent by an action stays sent;
a payment taken stays taken. AshWorkflow has no rollback (see [Error
handling](error-handling.md)), and undo does not add one.

Both are why `undoable?` defaults to false. Mark a transition undoable when
rewinding the *state* is the whole of what needs to happen. When it isn't,
model the reversal explicitly as a forward transition with its own action, so
the compensating work has somewhere to live:

```elixir
step :responding do
  transition :stand_down, to: :triage  # runs an action that cancels the page
end
```
