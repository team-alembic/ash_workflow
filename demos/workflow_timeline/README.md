# workflow_timeline

Demo for AshWorkflow's [transition log / workflow-history feature](https://github.com/team-alembic/ash_workflow):
a `transition_log` records one row per workflow event, and a LiveView draws
every incident's history as a horizontal band with a draggable time slider.

## The domain

An incident-response workflow — deliberately generic, not tied to any real
product:

```
(create) ─▶ triaging ──(auto: classify_severity)──▶ investigating ──(escalate)──▶ escalated ──(resolve)──▶ resolved
               │                                         │  ▲                          │
               │                                         │  every 90s: status reminder   │
               └──(on_error)──▶ triage_failed            │  (repeat, no state change)    │
                                                          └──(resolve)───────────────────▶ resolved
                                                          └──(8 min unresolved)──▶ escalated
```

It exercises every kind of workflow event the log records: an automatic step
with `on_success`/`on_error`, manual transitions, a one-shot timeout that
transitions (`:auto_escalate`), and — the one this feature exists for — a
*repeating* timeout (`:status_reminder`) that fires over and over without
changing state.

## One-time setup

```bash
mix setup
```

`mix setup` runs `priv/repo/seeds.exs`, which creates a few responders and ten
incidents with their transition logs already backdated across the last ten
days, so the timeline has something to show immediately.

## Running the demo

```bash
mix phx.server
```

Open http://localhost:4010/. Each row is one incident. Drag the slider: the
yellow playhead sweeps across every band at once, and each band's "state at
playhead" readout updates to whatever `state_at/2` says the incident was in
at that instant — read straight from its transition log, not from its current
`state` column.

The thin white ticks on a band are repeat-timeout rows (`from_state ==
to_state`) — the `:status_reminder` firing while nothing about the incident
changed. Each band also shows `state_entered_at` next to
`entered_current_state_at`; once a reminder has fired, the two diverge,
because `state_entered_at` moves every time the reminder resets its own
timer and `entered_current_state_at` does not.

Click **Generate incident history** to add another incident with a random,
backdated scenario without restarting the server.

## Tests

```bash
mix test
```

`test/incident_response_test.exs` covers the transition log itself: every
`triggered_by` value gets a dedicated test, a repeating timeout produces
`from_state == to_state` rows, `state_at/2` is checked before the first row,
between two rows, and after the last, and `entered_current_state_at` is shown
diverging from `state_entered_at` once a repeat fires.

`test/timeline_live_test.exs` renders the timeline, exercises the "Generate
incident history" button, and drives the slider via `render_change/3` to
confirm the per-band readout actually tracks the playhead rather than always
showing the current state.

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
  the repeating `:status_reminder` timeout's action.
- `lib/workflow_timeline/seeder.ex` — runs an incident through a random
  lifecycle using the real workflow actions, then rewrites the resulting
  transition-log rows' `occurred_at` (and the incident's denormalised
  `state_entered_at`) into the past, since `AshWorkflow.Changes.RecordEvent`
  always stamps rows with `DateTime.utc_now/0` and there is no other way to
  make a live action produce a backdated one.
- `lib/workflow_timeline_web/live/timeline_live.ex` — the timeline itself:
  turns each incident's `history/1` into segments and repeat-ticks, and
  resolves "state at playhead" locally as the slider moves.

## Why it's useful as a regression test

Every band on screen depends on `history/1`, `state_at/2`,
`entered_current_state_at`, and the five `triggered_by` values all agreeing
with each other and with the real column `state_entered_at` — so a change
that breaks any of those breaks this demo visibly, not just in an assertion.
