# Bounding `every` with `until`

> **Superseded.** The `repeat_started_at` design this document explains was
> replaced by [issue #89](https://github.com/team-alembic/ash_workflow/issues/89):
> `every` now writes its own per-`every` last-fired column instead of resetting
> `state_entered_at`, which is the "lapsed objection" option recorded below
> under "What is still open" — giving `every` its own anchor, with a
> never-fired column falling back to `state_entered_at` so that the first fire
> stays at `state_entered_at + interval`. That fallback also means an existing
> table needs no backfill. `until` now measures
> `state_entered_at` directly. See
> `AshWorkflow.Entities.Every`'s moduledoc for the current design. This
> document is kept for the history of how `repeat_started_at` came to exist
> and why it was eventually replaced, not as a description of current
> behavior.

## The question

`every` fires forever. The ask: give it a wall-clock ceiling — "remind every
2 days, but give up after 8" — spelled as a duration option alongside
`interval`, the way `fire_after` and `field` already sit on `timeout`.

This was originally built as `repeat_until` on `timeout`, before `every` was
extracted from `timeout`'s `repeat: true` option (`AshWorkflow.Entities.Every`,
extracted in a separate PR). Once `repeat` was gone, `until` moved with it —
it now bounds `every` directly, as a plain option rather than a nested entity.

Two things needed deciding when this started: the exact DSL spelling, and what
the bound is measured against. The second is the one that is not a one-liner,
and it survived the move to `every` unchanged.

## The DSL spelling

`until` sits directly on `every` as a plain option, alongside `interval` and
`action`:

```elixir
every :reminder do
  interval {2, :days}
  action :send_review_reminder
  until {8, :days}
end
```

and the inline form, matching how `every` already accepts one:

```elixir
every :reminder, {2, :days}, action: :send_review_reminder, until: {8, :days}
```

This is simpler than the design this replaced. Bounding a *timeout's*
`repeat: true` needed a nested `repeat` entity, because the bound's anchor had
to live somewhere distinct from the timeout's own `field` — `field` on
`Entities.Timeout` already meant "what `fire_after` measures against", and a
second, differently-named anchor for the bound would have been distinguished
from it only by a prefix (see the superseded version of this document, before
`every` existed, for that debate in full). `every` has no `field` at all — it
always measures against `state_entered_at` — so there is no collision to
avoid, and `until` can sit on `every` directly.

One capability was dropped in the move: the old `repeat` entity let a bound
name its own anchor (`field :signed_up_at`), for a bound about the record
rather than about the step. `every`'s flat `until` option has nowhere to put
that — adding it back would mean either reintroducing a nested entity (the
complexity this rewrite removes) or a second flat option
(`until_field`) that duplicates the "two anchors, one prefix apart" shape this
rewrite avoids for `every`'s own fields. Nobody has asked for a
per-record anchor on `every`'s bound yet, and `every` itself already declines
the equivalent capability for its own `interval` (see
`AshWorkflow.Entities.Every`'s moduledoc). Reintroducing it if the need arises
is a compatible addition to `until`, not a breaking change to it.

## What the bound is measured against

This is the part that is not a one-liner.

An `every` fires by resetting `state_entered_at` to now, every time it
fires — that reset is the entire mechanism, documented in
`AshWorkflow.Entities.Every`'s moduledoc. It is why the trigger's `where`
clause, `state_entered_at <= ago(interval)`, starts matching again the
interval after the last firing rather than never matching again.

A bound checked against that same field can never be reached. Every firing
pushes `state_entered_at` back to "now", so `state_entered_at <= ago(until)`
is exactly as false immediately after a fire as it is right after the record
first entered the step. The bound would need the record to sit still for the
whole bound, the one thing an `every` never lets it do.

Three candidates were considered for a fixed anchor instead:

A count of firings — track how many times `every` has fired and stop at N —
was rejected as the wrong feature. The ask is a wall-clock deadline ("give up
after 8 days"), not a firing budget ("give up after 4 reminders"). The two
coincide only when nothing ever changes `interval`, `check_interval` or the
scheduler's polling cadence for the life of the record. A count would need its
own attribute (an integer, incremented on every fire) and is a reasonable
follow-up feature, but it answers a different question from the one this asks.

`entered_current_state_at`, the calculation `workflow-history.md` already
computes for exactly this "state_entered_at lies about repeats" problem, was
also rejected. It reads the transition log and returns the `occurred_at` of
the most recent row where `from_state != to_state`, filtering out the very
rows a firing writes, and reusing it would have meant no new attribute at
all. It cannot be filtered on, though:
`AshWorkflow.Verifiers.ValidateTimeoutFields.validate_calculation_is_expression/3`
already rejects any timeout `field` that is a module calculation rather than
an expression calculation, because the trigger's `where` clause is evaluated
by the data layer and a module calculation is computed in Elixir after the
read. `EnteredCurrentStateAt` is a module calculation — it queries the
transition log — so it hits exactly that rule. It would also make the bound
depend on `transition_log` being configured, which the ask does not call for.

A second attribute, `repeat_started_at`, is what was built. Added only when
some `every` bounds its firing with `until`
(`AshWorkflow.Transformers.AddAttributes.add_repeat_started_at/1`), it is
written to the same instant as `state_entered_at` on every genuine step entry
— a manual transition, an automatic step completing, a transition timeout, an
undo, the initial create — and left untouched by an `every`'s own firing
(`AshWorkflow.Changes.RecordEvent`'s `repeat_fire?` option, `false` at every
entry site and `true` only where `AshWorkflow.Transformers.AddActions`
injects an `every`'s own `RecordEvent`). Being a plain column rather than a
calculation, both `AshWorkflow.Scheduler.Oban`'s trigger `where` and
`AshWorkflow.Scheduler.Precise`'s `Work.match` re-check can filter on it
directly, the same way they already filter on `state_entered_at`.

`AshWorkflow.Transformers.AddScheduler.until_match/2` folds the check into
`Work.match` as an extra clause: `is_nil(repeat_started_at) or
repeat_started_at > ago(until)`. Once `repeat_started_at` is further in the
past than the bound, this clause is false forever for the current step visit
— the record never matches again until it leaves and re-enters the step.
Because both schedulers execute through the same `Work.match`, correctness
lives in exactly one place: even though `AshWorkflow.Scheduler.Precise`'s
recovery sweep arms timers from a separate, narrower filter
(`Precise.Timeline.due_records/3`), every timer — swept or precisely armed —
fires through `fire/4`, which re-reads the record and re-checks the full
`Work.match` before running anything. A bound-exceeded record armed by an
over-eager sweep therefore still fires nothing.

Left there, though, a bound-exceeded record would keep matching the sweep's
narrower filter forever, arming a timer on every `look_ahead_ms` tick that
`fire/4` immediately discards — one wasted read and one wasted timer per
record per tick, indefinitely, for every record that has run out its
reminders. `due_records/3` also filters on the bound now, checked against
"now" rather than the horizon's `cutoff`: a record already bound-exceeded is
excluded from the sweep outright, rather than merely from running once armed.

`is_nil(repeat_started_at)` treats a record written before this attribute
existed — a new column on what may be an existing table — as "bound not yet
reached" rather than raising or refusing to poll it. Backing it with `NOT
NULL` and a migration that backfills every existing row from
`state_entered_at` was rejected: it assumes every existing row's current
`state_entered_at` already reflects a genuine entry rather than a stale
firing, which is precisely the fact this attribute exists because
`state_entered_at` cannot be trusted to report. Leaving it permanently `nil`
was also rejected, once it was pointed out that "bound not yet reached" would
then mean "never bounded" for every record already repeating when a bound was
added to its `every`, the opposite of what enabling the option asks for.
`AshWorkflow.Changes.RecordEvent` instead backfills lazily: a fire that finds
`repeat_started_at` still `nil` sets it to the pre-firing `state_entered_at` —
the last instant this `every` actually reset the clock — rather than leaving
it unset. That is the closest available estimate of when repeating started,
and it is only ever read once, on the first fire after the attribute exists;
every fire after that finds it already set and leaves it alone.

## The lapsed objection, and what is still open

A fourth option, not a new attribute but a different one moved, would invert
which attribute `every` writes: leave `state_entered_at` alone as the genuine
entry time, and have `every` write a new `last_fired_at` instead, with
`interval` measured against `coalesce(last_fired_at, state_entered_at)`. That
would make `state_entered_at` truthful again for every other deadline on the
step, and remove the reason `AshWorkflow.Calculations.EnteredCurrentStateAt`
exists at all. It would also remove `AshWorkflow.Transformers.AddScheduler`'s
trigger-ordering workaround (`every_works` scheduled before `timeout_works`,
documented in `AddScheduler`'s moduledoc), since a transition timeout would
no longer be racing `every` for the same attribute.

When this was first considered, on `timeout`'s `repeat: true`, it was rejected
because it changed the existing, released `repeat` mechanism rather than
adding beside it: every workflow already using `repeat: true` measured
`fire_after` against `state_entered_at`, and moving that to a new column was
a breaking change to a feature the bound was not asked to touch.

`repeat` is gone now, replaced entirely by `every`. That objection no longer
holds — there is no released `every` behavior this would break, since `every`
already resets `state_entered_at` and nothing currently depends on the
alternative. Giving `every` its own anchor is accordingly recorded here as the
open follow-up, not a rejected alternative: a real design question the
maintainer has not decided, deliberately left alone by this change, which
only renames `repeat_until` to `until` and re-homes it on `every`.

## What happens when the bound is reached

Reaching the bound only stops the firing. It does not transition state —
compose a second, non-repeating `transition_to` timeout with a `fire_after`
equal to the bound for "give up and move on":

```elixir
step :awaiting_response do
  every :reminder do
    interval {2, :days}
    action :send_review_reminder
    until {8, :days}
  end

  timeout :give_up, fire_after: {8, :days}, transition_to: :escalated
end
```

`give_up` is an ordinary, non-repeating transition timeout — the same
mechanism `documentation/topics/timeouts-and-deadlines.md` already documents
under "Transition timeouts" — given a `fire_after` equal to the bound. It
needs no new field on `Entities.Every`, no new case in
`AshWorkflow.Transformers.AddScheduler`, and no new question about what
`transition_to` means when it is attached to a bound rather than to a
deadline. The two share nothing at runtime; they happen to agree on one
number.

The cost of this choice is that a workflow author writes the bound twice —
once on `until`, once on `give_up`'s `fire_after` — rather than once. That is
judged cheaper than a second, transition-shaped meaning for the bound.
