# ash_workflow_demo

Conference stage demo for [AshWorkflow](https://github.com/team-alembic/ash_workflow). An ATS pipeline where attendees submit themselves from their phones, two reviewers who are played by the workflow itself wave them through or turn them down, a background check answers from outside the application, and El Jefe picks one.

## One-time setup

```bash
mix setup
```

## Running the demo

Terminal 1 — expose to the internet:

```bash
cloudflared tunnel --url http://localhost:4000
# copy the generated https://<xxx>.trycloudflare.com URL
```

Terminal 2 — start Phoenix with the tunnel URL:

```bash
TUNNEL_URL=https://<xxx>.trycloudflare.com mix phx.server
```

Open http://localhost:4000/ — that's El Jefe's kanban. Project it. The QR in the corner points at `<tunnel>/apply`.

Open `<tunnel>/dbs` on a second screen or a phone. That's the Disclosure & Background Bureau portal, and it is the only way a candidate leaves `:background_check` before the check lapses.

If you forget to set `TUNNEL_URL`, the dashboard shows a text input where you can paste the URL at runtime.

One more page, `/timeline`, reading the same `transition_log` and touching neither the kanban's look nor its behaviour. `/history` and `/rewind` were two pages during development and now redirect here.

### The playhead

Open it after a few candidates have moved. Each candidate gets a band spanning the same window, which runs from the earliest row any candidate logged — the first submission — to a minute past the latest one.

Both ends come from the log rather than the wall clock. A window ending at `now` keeps widening for as long as the server is up, so a demo left running between sessions squeezes every band into the left edge and leaves most of the slider scrubbing through empty time.

Drag the slider: the yellow playhead sweeps across every band at once, and each candidate's "state at playhead" readout updates to whatever the log says was true at that instant, not the candidate's current `state` column. This is log-backed and live (PubSub-driven, like every other page here), deliberately not built on Ash temporal resources / Postgres 19 — that is a separate, later piece of this talk.

Clicking a candidate's name opens their own `/c/:id` page.

### The log behind each band

Click a band, or the ▸ beside it, to unfold the rows it was drawn from: `#`, `when`, `from → to`, `transition`, `triggered by` (`submitted`, `automatic step`, `person`, `timeout`, `error path`, or `undo`), and `undoes` — a pointer to the row an undo row reverses.

The unfolded list is cut at the playhead. Scrub left and the rows after it leave the list, with a count of what is hidden; scrub right and they come back. The `#` column keeps counting from the first row, so a row's number does not change as the playhead moves and an `↩ row N` pointer stays readable.

`:offer`, `:veto`, and the bureau's `:dbs_clear` / `:dbs_flag` are undoable for 30 minutes (`undo do within({30, :minutes}) end`). Click **undo → \<state\>** on a candidate that has one:

1. The candidate rewinds to the state the log says it actually came from.
2. A *new* row appears, `triggered by: undo`, marked `↩ row N` — pointing at the row it reverses. That row is still there, struck through. Nothing was edited or deleted.

That struck-through row is the whole argument for recording an undo as a pointer rather than a flag on the row it reverses. `AshWorkflow.TransitionLog.effective/1` reads the same rows and drops the reversed one, which is where the strike-through comes from.

A few things worth clicking:

- **Undo twice.** The second undo is a redo — it reverses the undo row, landing back where the first undo rewound out of.
- **A freshly screened candidate says "nothing to undo".** Its most recent state change came from Janine's automatic `:record_hr_screen`, which is not an undoable transition.
- **A bystander swept by `:offer`'s cascade from `:final_approval` still shows an undo button.** Undo resolves by `(from_state, to_state)` edge, not by which named transition wrote the row, and `:veto` shares that exact edge (`:final_approval -> :rejected`) with the `:slot_taken` cascade. A bystander swept from any *other* step stays correctly non-undoable, since no undoable transition shares that edge. See the comment on the `:final_approval` step in `candidate.ex`.

## Demo flow

1. Open the dashboard. QR code is top-right.
2. Audience scans QR, lands on `/apply`. Submitting puts them on `:hr_screen`, waiting on Janine.
3. Janine comes back after a delay drawn for that candidate. She scores the pitch out of ten and writes a line about it. Four or better goes to the background check; anything less is rejected there and then. Nobody clicked anything.
4. On the DBS portal, the candidate is listed by their `dbs_reference`. Return a disclosure and they carry an absurd offence for the rest of the pipeline. Ignore the portal and the bureau answers for itself after 90 seconds, disclosing something about three times in five.
5. Steve, the engineering lead, comes back after his own delay and writes up the interview. He has read the disclosure and is unbothered by it. Four or better reaches El Jefe.
6. El Jefe's column is the only one with buttons. **Make the offer** hires that candidate and sweeps every other candidate still moving — at any step — to `:rejected` in the same instant. **Veto** rejects just that one.
7. Candidates watch all of it on `/c/:id`, including their own disclosure.
8. **Insert Random Candidate** injects a fake one if the audience is shy.
9. **Reset the Req** sweeps everyone still in flight to `:rejected` so you can run it again.

Every waiting step has a deadline that advances the candidate rather than stalling them, so the board keeps moving whether or not you touch it, and El Jefe's own 45-second timer makes the offer for him if he dithers.

## Who moves a candidate

Three parties, and only one of them is in the room.

| Party | Steps | Played by |
|---|---|---|
| Janine, HR | `:hr_screen` → `:hr_decision` | the workflow, after a per-candidate delay |
| The bureau | `:background_check` → `:bureau_result` | the `/dbs` portal or the webhook, from outside, or itself on a timeout |
| Steve, engineering lead | `:lead_interview` → `:lead_decision` | the workflow, after a per-candidate delay |
| El Jefe | `:final_approval` | you, with the only two buttons on the board |

Each reviewer is a wait step whose only exit is their own deadline, followed by an instantaneous decision step that runs their action and branches on the score with conditional `on_success` routes. The decision steps never visibly hold a card, so the board files each pair under one column.

The bureau is the same shape with the roles reversed. `:background_check` waits for an answer from outside, and its `:bureau_responds` deadline is the fallback rather than the mechanism: when it fires, `:bureau_result` rolls a result itself, disclosing something 60% of the time. Nobody has to work the portal for the demo to stay funny, and working it overrides the roll.

Both delays are drawn once on submission and stored on the record. That is what lets a whole room apply in the same second and still come back staggered — the delay is data, not a sleep holding a database connection.

## Tests

```bash
mix test
```

Covering: initial state, verify→review transition, hire cascade, cascade leaves terminal states alone, auto-reject timeout action, list + get code interface, and the DBS chain — reference issued on hire, clear and flagged results, duplicate and unknown references, and hire through to `:hired`.

`test/candidate_transition_test.exs` covers the transition log itself: every `triggered_by` value (`:initial`, `:automatic`, `:error_path`, `:manual`, `:timeout`), `history/1` ordered by `occurred_at`, `state_at/2` before the first row / between two rows / after the last, undo leaving the reversed row in place with a pointer to it, undoing an undo as a redo, the 30-minute undo window expiring, and the `:final_approval` edge-sharing nuance between `:veto` and `:slot_taken`.

`test/timeline_live_test.exs` covers the `/timeline` page: the band render, the slider tracking the playhead via `render_change/3`, the window starting at the earliest logged row, a new candidate appearing on the next PubSub broadcast, unfolding and folding a candidate's log, the name linking to `/c/:id`, rows leaving and rejoining the list as the playhead moves, row numbers counting from the first row rather than the first shown one, undo and redo through the LiveView, a candidate whose last change was automatic offering nothing to undo, and the `/history` and `/rewind` redirects.

## Architecture

- `lib/ash_workflow_demo/ats/candidate.ex` — the star. One Ash resource whose `workflow do` block generates the state machine, transitions, and Oban triggers.
- `lib/ash_workflow_demo/ats/candidate/cascade.ex` — `after_action` hook on `:offer` that sweeps every other in-flight candidate to `:rejected` through the `slot_taken` transition. A distinct transition name from El Jefe's `veto`, so the log says whether a candidate was turned down or simply beaten to the slot.
- `lib/ash_workflow_demo/ats/candidate/janine_screens.ex` and `steve_interviews.ex` — the two reviewers. Neither sleeps; the delay belongs to the step's deadline.
- `lib/ash_workflow_demo/ats/candidate/set_response_delays.ex` and `start_lead_clock.ex` — where each reviewer's deadline is stamped.
- `lib/ash_workflow_demo/ats/dbs_bureau.ex` — the caller-side half of an external event, correlating on `dbs_reference`.
- `lib/ash_workflow_demo/ats/candidate/dbs_offences.ex` — the disclosures. Crimes against a codebase, never real offences: the candidate on the projector is a real person in the room.
- `lib/ash_workflow_demo_web/live/dbs_bureau_live.ex` — the portal, deliberately styled as a different application.
- `lib/ash_workflow_demo/ats/candidate/notifier.ex` — Ash notifier that broadcasts changes to Phoenix.PubSub.
- `AshWorkflow.Scheduler.Precise` — declared in the resource's `workflow` block. Arms a timer per deadline rather than polling cron, which is how deadlines of a few seconds are expressible at all. This replaced a hand-rolled 1-second ticker.

  One caveat found while building this. `Timeout`'s `field` option documents support for a calculation, and the two reviewer deadlines read far better as `state_entered_at` plus the candidate's delay than as stamped columns. The scheduler builds the right SQL filter for such a calculation, then arms its timer from the unloaded value on the record and crashes `AshWorkflow.Scheduler.Precise.Timeline` with a `FunctionClauseError` in `as_datetime/1`. The deadlines here are real columns because of it.
- `lib/ash_workflow_demo/tunnel_url.ex` — Agent storing the public tunnel URL for the QR code.
- `lib/ash_workflow_demo_web/live/dashboard_live.ex` — El Jefe's kanban.
- `lib/ash_workflow_demo_web/live/candidate_live.ex` — candidate's mobile self-view.
- `lib/ash_workflow_demo_web/live/apply_live.ex` — public submission form.
- `lib/ash_workflow_demo/ats/candidate_transition.ex` — the transition log, scaffolded by `mix ash_workflow.gen.transition_log AshWorkflowDemo.ATS.Candidate` and hand-adjusted (the generated `:workflow` relationship renamed to `:candidate`). No `belongs_to_actor`: this demo has no actor/auth resource, and `triggered_by` alone is enough to say who or what moved a candidate.
- `lib/ash_workflow_demo_web/live/timeline_live.ex` — the `/timeline` page: the all-candidates playhead, with each candidate's log and undo/redo folded behind its band. Built from `demos/workflow_timeline`'s `timeline_live.ex` and `undo_live.ex`, which are still two pages there.
- `lib/ash_workflow_demo_web/controllers/timeline_redirect_controller.ex` — sends `/history` and `/rewind` to `/timeline`.

## Why it's flashy

- The entire hiring pipeline, DBS check and two approval gates included, is one `workflow do` block.
- Timeouts genuinely fire live — not mocked.
- Every screen updates in real time via Phoenix.PubSub.
- One click sweeps every other candidate, at every step at once, to `:rejected`.
- A stranger's HTTP request, from a different screen on a different URL, resumes a workflow that was sitting still.
- El Jefe's own veto, undone within 30 minutes, un-happens without erasing the row that recorded it.
- One slider rewinds every candidate on the board at once, live, from nothing but an append-only log.
