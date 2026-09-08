# Design: undo

Status: implemented. Builds directly on the transition log
(`documentation/design/workflow-history.md`) — undo is not viable without it.

## The problem

Workflows encode decisions, and people make them by mistake: the wrong
candidate rejected, the wrong incident closed, approve clicked on the row above
the intended one. Until now the only remedy was to model the reversal by hand
as a forward transition — one corrective edge per mistake worth recovering
from, each needing its own name, target, and policy.

The transition log changed what is possible. It already records, per event,
where the record came from, where it went, which transition moved it, who was
acting, and when. That is everything a generic undo needs to know, so undo
stops being a feature that requires new bookkeeping and becomes a feature that
*reads* bookkeeping already being kept.

## The decision

**An undo appends a new log row pointing at the row it reverses. It never
mutates or deletes one.**

The row carries `triggered_by: :undo` and `undoes_id`, a self-referencing
foreign key on the log resource.

This is the whole design; everything below follows from it.

### Why a pointer, and not an `undone` flag on the reversed row

The alternative considered — and rejected — was marking the reversed row
`undone: true` (or `undone_at`/`undone_by_id`) and filtering it out of history.
It is genuinely more convenient in one place: a timeline UI gets one row per
decision, struck through, with no pairing logic in the view.

It loses on five counts.

**It contradicts side effects.** Automatic steps run actions. A record that sat
in a state for eight seconds may well have had its Oban trigger fire and an
email sent. The log is the only artifact explaining why that email exists.
Filtering the row out of `state_at/3` leaves an unexplainable side effect and a
history asserting the workflow was never in the state that caused it. The eight
seconds were not *incorrect state* — they were correct state that was regretted.
What wants recording is that the event was **superseded**, not that it **never
happened**, and a flag can only express the second.

**It breaks the invariant the transition log just paid for.** That design
splits `state_entered_at` (timer anchor, a write-through projection of the log)
from `entered_current_state_at` (derived from the log). An undo must reset the
anchor column — but with no row to project from, the calculation walks back to
the pre-undo row and reports the earlier time while the column reports the
rewind. The two silently disagree and "projection of the log" stops being true.
With a row, both fall out unchanged.

**One row becomes three columns.** Matching what a row gives free needs
`undone_at`, `undone_by_id`, and probably `undone_reason` — and even then the
undo has no *position* in the log, so a timeline cannot order "approved 10:00 →
undone 10:08" without special-casing outside the sort.

**Undo of an undo does not fit.** A boolean flapping true → false → true keeps
only its final value. With rows, redo is a row pointing at a row, and needs no
rule of its own.

**It makes the log mutable.** The generated log is `defaults [:read]` plus a
single `create`; append-only is the shape of the resource, not an accident. A
flag adds an update action, an update policy, and a verifier requirement to a
resource the *user* owns and may have hand-modified — and every downstream
consumer loses "rows never change", the property that makes a log cheap to
stream, cache, or replicate.

It also saves nothing at the state-machine layer: the `state` column still
moves backwards, so ash_state_machine still needs the reverse edge declared at
compile time either way.

The general shape of the argument: **a flag answers one question and destroys
the other; a pointer answers both.** Here the destroyed one is "what actually
happened", which is the reason the log exists at all. The convenience the flag
buys is a *presentation* decision, and pushing a presentation decision into
storage makes it unrecoverable. With the pointer, the timeline UI does one join
and renders the struck-through pair — the same result, decided in the view.

### Two readings, one log

Because nothing is destroyed, both accounts stay derivable:

| Call | Answers |
|---|---|
| `history(record)`, `state_at(record, at)` | what actually happened |
| `history(record, effective: true)`, `state_at(record, at, effective: true)` | what stands after corrections |

`AshWorkflow.TransitionLog.effective/1` computes the second by collecting the
non-nil `undoes_id` values and dropping the rows they name. Redo needs no
special case: undoing an undo marks the undo row superseded, leaving the redo
row and the state it lands on standing.

The effective reading applies every known correction regardless of when it
happened. It answers "what do we now say was true at `at`", not "what did the
log say at `at`". The second question is answerable too — filter by
`occurred_at` first — but it has not been needed, so it has no API.

### Undo moves backward in state and forward in the log

This is what dissolves the tension between rewinding and modelling corrections
as forward transitions. The user gets rewind semantics; the system keeps
append-only semantics; the audit trail records that someone reversed a
decision rather than pretending it never happened.

## Decisions

### Opt-in per transition, not per workflow

`undoable?: false` is the default, and an `undo` block alone undoes nothing.
Undo cannot be made safe by the extension — a transition that sent an offer or
took a payment stays sent and taken — so the author marks the edges where
rewinding is safe on its own. A workflow declaring `undo` with nothing undoable
is a compile error rather than an action that refuses every call.

### `undoable?: true` is the only gate on what can be undone

Undo resolves the most recent log row where `from_state != to_state`, and
refuses unless that row's `{from_state, to_state}` is a declared undoable edge.
That single rule covers everything else for free: automatic steps, timeouts,
error paths and the `:initial` row all fail it, because none corresponds to an
undoable transition.

Conditional transitions contribute one edge per route, so undo permits exactly
the moves the transition could actually have made — not the cross product.

Rows where `from_state == to_state` are skipped when finding the head. A
repeating timeout writes one to re-arm its own trigger; it moved nothing, so it
is not what an undo should reverse. Without this a pending reminder would block
undo entirely.

### Redo is the same code path read backwards

An `:undo` row is reversed by checking its edge in the opposite direction —
which is the original forward edge, and therefore already declared undoable.
`AddStateMachine` registers both directions per undoable edge so the state
machine permits the redo leg.

### Undo gets its own policy, not the step's

An undo spans two states, and which step it rewinds into is known only after
the log is read, so no step's policy could correctly apply. `undo do policy ...
end` scopes a check to the generated action; without one it falls under the
extension's default-allow like every other generated action.

### Not atomic, but guarded

The rewind target is only known after reading the log, so the `undo` action
sets `require_atomic? false` — the same reason `ConditionalTransition` does. A
changeset filter on the current state closes the resulting window: a concurrent
forward transition between the read and the write makes the update match no
rows and fail, rather than rewinding to a state that is no longer the one being
undone.

## What this is not

**Not attribute restoration.** The log records states, not the values a
transition with `accept` wrote. Undo restores state only. Adding an `input` map
column is the point at which this stops being a transition log and starts being
a half-built event store — the history design already draws that line, and this
holds it.

**Not compensation.** A step whose action sent an email still sent it.
`documentation/topics/error-handling.md` assigns saga compensation to Reactor
and this does not change that. A transition whose target is an automatic step
is undoable only until that step's trigger fires, after which the head of the
log is the automatic row and undo refuses — correct, and worth documenting
because it will surprise people.

## Rejected alternatives

**`undone` flag on the reversed row.** Above.

**Deleting the reversed row.** Loses the audit trail outright, and breaks
`state_at/3` for every timestamp in the reversed interval.

**Undo as generated corrective transitions.** Considered: have `undoable?:
true` generate a named reverse transition per edge, keeping the model strictly
forward-only. Rejected because the generated action names are unpredictable
(`unapprove`? `undo_approve`?), each one needs its own policy, and undoing an
undo would require a third generated action. One `undo` action reading the log
handles all of it, including conditional transitions whose forward target was
itself only known at runtime.

**Storing the undo target on the workflow row** (a `previous_state` column).
Works for exactly one level, cannot express redo, and duplicates what the log
already knows.
