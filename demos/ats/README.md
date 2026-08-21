# ash_workflow_demo

Conference stage demo for [AshWorkflow](https://github.com/team-alembic/ash_workflow). An ATS pipeline where attendees submit themselves from their phones, El Jefe picks one, and everyone else cascades to `:position_filled`.

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

If you forget to set `TUNNEL_URL`, the dashboard shows a text input where you can paste the URL at runtime.

## Demo flow

1. Open dashboard. QR code is top-right.
2. Audience scans QR → lands on `/apply`. Submitting creates a candidate in `:verifying`; within a few seconds they progress to `:review` with a fake AI score.
3. On a `:review` card, a 30-second countdown runs. If El Jefe doesn't hire or reject, the workflow auto-rejects.
4. Click **Hire** on one card — that candidate becomes `:hired` and every other `:review` candidate cascades to `:position_filled`.
5. Candidates watch themselves on `/c/:id` — a mobile-optimised view with their current state. The winner sees confetti.
6. **Insert Random Candidate** injects a fake one if the audience is shy.
7. **Reset the Req** clears `:review` candidates to `:position_filled` so you can run the demo again.

## Tests

```bash
mix test
```

Seven tests cover: initial state, verify→review transition, hire cascade, cascade leaves terminal states alone, auto-reject timeout action, list + get code interface.

## Architecture

- `lib/ash_workflow_demo/ats/candidate.ex` — the star. One Ash resource whose `workflow do` block generates the state machine, transitions, and Oban triggers.
- `lib/ash_workflow_demo/ats/candidate/fake_score.ex` — the verify step's "AI scorer". Sleeps 2–5 seconds, assigns a random score and canned reason. Honours `:fast_tests` app env.
- `lib/ash_workflow_demo/ats/candidate/cascade.ex` — `after_action` hook on `:hire` that transitions all other non-terminal candidates to `:position_filled`.
- `lib/ash_workflow_demo/ats/candidate/notifier.ex` — Ash notifier that broadcasts changes to Phoenix.PubSub.
- `lib/ash_workflow_demo/demo_scheduler.ex` — 1-second-tick GenServer that invokes AshOban schedulers directly. Sub-minute granularity for the 30-second timeout (free Oban cron is minute-level).
- `lib/ash_workflow_demo/tunnel_url.ex` — Agent storing the public tunnel URL for the QR code.
- `lib/ash_workflow_demo_web/live/dashboard_live.ex` — El Jefe's kanban.
- `lib/ash_workflow_demo_web/live/candidate_live.ex` — candidate's mobile self-view.
- `lib/ash_workflow_demo_web/live/apply_live.ex` — public submission form.

## Why it's flashy

- The entire hiring pipeline is ~25 lines of DSL.
- Timeouts genuinely fire live — not mocked.
- Every screen updates in real time via Phoenix.PubSub.
- One click cascades the whole "losers" population to `:position_filled`.
