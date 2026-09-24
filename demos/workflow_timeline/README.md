# workflow_timeline

Demo for AshWorkflow's [transition log / workflow-history feature](https://github.com/team-alembic/ash_workflow):
a `transition_log` records one row per workflow event, and a LiveView draws
every incident's history as a horizontal band with a draggable time slider.

Two pages, on the same workflow:

| Page | Shows |
|---|---|
| `/` | **History.** Every incident as a band, with a playhead that replays `state_at/2` across all of them at once |
| `/undo` | **Undo.** The same workflow with every manual transition `undoable?: true`, and a toggle between the two readings of one log |

## The domain

An incident-response workflow — deliberately generic, not tied to any real
product:

```
(create) ─▶ triaging ──(auto: classify_severity)──▶ investigating ──(escalate)──▶ escalated ──(resolve)──▶ resolved
               │                                         │  ▲                          │
               │                                         │  every 90s: status reminder   │
               └──(on_error)──▶ triage_failed            │  (no state change)            │
                                                          └──(resolve)───────────────────▶ resolved
                                                          └──(8 min unresolved)──▶ escalated
```

It exercises every kind of workflow event the log records: an automatic step
with `on_success`/`on_error`, manual transitions, a one-shot timeout that
transitions (`:auto_escalate`), and — the one this feature exists for — an
*`every`* (`:status_reminder`) that fires over and over without changing
state.

## One-time setup

```bash
mix setup
```

`mix setup` runs `priv/repo/seeds.exs`, which creates a few responders and ten
incidents with their transition logs already backdated across the last ten
days, so the timeline has something to show immediately — plus three incidents
on the undo page, left in the present because undo there is configured `within
{1, :hours}`.

## Running the demo

```bash
mix phx.server
```

Open http://localhost:4010/. Each row is one incident. Drag the slider: the
yellow playhead sweeps across every band at once, and each band's "state at
playhead" readout updates to whatever `state_at/2` says the incident was in
at that instant — read straight from its transition log, not from its current
`state` column.

The thin white ticks on a band are same-state rows (`from_state ==
to_state`) — the `:status_reminder` every firing while nothing about the
incident changed. Each band also shows `state_entered_at`; a reminder firing
leaves it alone, because the every writes its own `investigating_status_reminder_last_fired_at` column and leaves
`state_entered_at` where the transition into the step set it.

Click **Generate incident history** to add another incident with a random,
backdated scenario without restarting the server.

### The undo page

Open http://localhost:4010/undo. This is the same incident workflow, copied
into `UndoableIncident` with an `undo` block and `undoable?: true` on every
manual transition — the diff between the two resources is deliberately just
those four lines.

Escalate an incident, then hit **undo**. Three things happen at once, and the
third is the point:

1. The incident goes back to `investigating`.
2. A *new* log row appears, `triggered_by: :undo`, marked `↩ row 3` — pointing
   at the row it reverses. The reversed row is still there, struck through.
   Nothing was edited or deleted.
3. The **Showing: what happened / corrected history** toggle now changes the
   band. The literal reading still contains the red `escalated` segment,
   because the incident really was escalated for those few seconds. The
   corrected reading drops it.

Both readings come out of the same rows, which is the entire argument for
recording an undo as a pointer rather than as a flag on the row it reverses:
had the reversed row been flagged and filtered away, only the second reading
would exist.

A few other things worth clicking:

- **Undo twice.** The second undo is a redo — it reverses the undo row, which
  puts `escalated` back. No extra table or function for this case; the
  corrected reading just follows the pointers.
- **`resolve` from either state.** It is one action shared between
  `investigating` and `escalated`, so it has two undoable edges. Undo rewinds
  to whichever state the log says it actually came from.
- **A freshly triaged incident says "nothing to undo".** Its most recent state
  change came from the automatic `:classify_severity` step, which is not an
  undoable transition and cannot be made one — by the time you could click, the
  action has already run.

## Tests

```bash
mix test
```

`test/incident_response_test.exs` covers the transition log itself: every
`triggered_by` value gets a dedicated test, an every produces
`from_state == to_state` rows, `state_at/2` is checked before the first row,
between two rows, and after the last, and an every firing is shown leaving
`state_entered_at` unchanged.

`test/timeline_live_test.exs` renders the timeline, exercises the "Generate
incident history" button, and drives the slider via `render_change/3` to
confirm the per-band readout actually tracks the playhead rather than always
showing the current state.

`test/undo_live_test.exs` covers the undo page: that undoing rewinds the
incident and leaves the reversed row in the log struck through with a pointer
to it, that the effective toggle changes which segments the band draws, and
that an incident whose last change came from the automatic step offers nothing
to undo.

## Architecture

- `lib/workflow_timeline/incident_response/incident.ex` — the workflow
  resource. `transition_log` is configured here, with `belongs_to_actor` set
  to `Responder`.
- `lib/workflow_timeline/incident_response/incident_transition.ex` — the
  hand-written transition log resource (`mix ash_workflow.gen.transition_log`
  is expected to scaffold this shape once it lands; this file is written to
  match it). Also carries a `:backdate` action used only for seeding.
- `lib/workflow_timeline/incident_response/responder.ex` — the actor
  resource captured on each log row.
- `lib/workflow_timeline/incident_response/incident/classify_severity.ex` —
  the `:triaging` step's automatic action.
- `lib/workflow_timeline/incident_response/incident/send_status_update.ex` —
  the `:status_reminder` every's action.
- `lib/workflow_timeline/seeder.ex` — runs an incident through a random
  lifecycle using the real workflow actions, then rewrites the resulting
  transition-log rows' `occurred_at` (and the incident's denormalised
  `state_entered_at`) into the past, since `AshWorkflow.Changes.RecordEvent`
  always stamps rows with `DateTime.utc_now/0` and there is no other way to
  make a live action produce a backdated one.
- `lib/workflow_timeline/incident_response/undoable_incident.ex` — the same
  workflow with an `undo` block and `undoable?: true` on every manual
  transition. A near-copy on purpose: the two files are meant to be read side
  by side.
- `lib/workflow_timeline/incident_response/undoable_incident_transition.ex` —
  its log, differing from `incident_transition.ex` only by the
  self-referencing `undoes` relationship that undo rows point through.
- `lib/workflow_timeline_web/live/undo_live.ex` — the undo page: the same
  band derivation as the timeline, drawn from either `history/1` or
  `history(effective: true)`, over a table that always shows every row.
- `lib/workflow_timeline_web/live/timeline_live.ex` — the timeline itself:
  turns each incident's `history/1` into segments and repeat-ticks, and
  resolves "state at playhead" locally as the slider moves.

## Why it's useful as a regression test

Every band on screen depends on `history/1`, `state_at/2`, and the
`triggered_by` values all agreeing with
each other and with the real column `state_entered_at` — so a change that
breaks any of those breaks this demo visibly, not just in an assertion.

The undo page adds the append-only guarantee to that set: if an undo ever
started mutating the row it reverses, the struck-through row and its `↩ row N`
pointer would vanish from the table and the two readings of the band would
collapse into one.
