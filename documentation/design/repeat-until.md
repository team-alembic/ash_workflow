# Bounding a repeat

## The question

`repeat: true` fires a timeout forever. The ask: give it a wall-clock ceiling —
"remind every 2 days, but give up after 8" — spelled as a duration tuple
alongside `repeat`, the way `fire_after` already is.

Two things need deciding: the exact DSL spelling, and what the bound is
measured against. The second turned out to be the whole problem.

## The DSL spelling

Three shapes were on the table:

```elixir
# A. Flat options beside `repeat`
timeout :reminder, fire_after: {2, :days}, repeat: true, repeat_until: {8, :days}, ...

# B. `repeat` grows from a boolean into a boolean-or-keyword
timeout :reminder, fire_after: {2, :days}, repeat: [until: {8, :days}], ...

# C. `repeat` becomes an entity with a block
repeat true do
  until {8, :days}
  field :signed_up_at
end
```

(C) won, after (A) shipped first and was reshaped.

(B) was rejected outright. Growing `repeat` into `{:or, [:boolean, :keyword]}` means every reader of `timeout.repeat` gains a second shape to match on, for a feature only some timeouts use.

(A) works, and is what the first version of this did. It falls down once the bound needs an anchor of its own. `field` on the timeout anchors `fire_after`, and the bound needs a different anchor that repeating does not reset, so (A) ends with `field` and `repeat_until_field` side by side on one entity, meaning two different things, distinguished only by a prefix.

(C) puts the bound and its anchor inside the thing they belong to, so `field` inside `repeat` is unambiguously the bound's anchor. It follows `retry`, already a singleton entity on the same `timeout`.

### What Spark allows, and what that costs

`repeat true do ... end` reads redundantly. `repeat do ... end` would be better, and Spark cannot express both it and the inline `repeat: true`.

`Spark.Dsl.Entity.fetch_single_argument_entities_from_opts/4` is what expands an inline `repeat: true` into a nested entity. It only considers entities whose `args` holds exactly one element, and it uses that element verbatim as a keyword key. So the inline form requires `args: [:enabled?]`, one plain atom. An optional arg (`{:optional, :enabled?, true}`) crashes it, and an empty `args` makes it skip the entity entirely, which drops the inline form.

Meanwhile a required positional arg is what forces the block form to carry it: with `args: []` the block would be `repeat do ... end`, but then `repeat: true` no longer compiles anywhere.

Two entity definitions under the same `repeat` key, one per shape, was tried. The inline path accepts it, and the generated macros then collide: a block-position `repeat true` reaches the zero-arg macro and fails in `Access.get/3`.

So the choice was between `repeat do ... end` and keeping `repeat: true`. Keeping it won: `repeat: true` appears 35 times across this repository alone, including a demo application, and the inline one-liner is the common case while the bound is the rare one. Making the common case worse to make the rare case prettier is the wrong trade.

## What the bound is measured against

This is the part that is not a one-liner.

A repeating timeout works by resetting `state_entered_at` (or a custom
`field`) to now, every time it fires — that reset is the entire mechanism,
documented in `AshWorkflow.Entities.Timeout`'s moduledoc and
`usage-rules/timeouts.md`. It is why the trigger's `where` clause,
`field <= ago(fire_after)`, starts matching again 2 days after the last
firing rather than never matching again.

A bound checked against that same field can never be reached. Every firing
pushes `field` back to "now", so `field <= ago(until)` is exactly as
false immediately after a repeat as it is right after the record first
entered the step. The bound would need the record to sit still for
the whole bound, the one thing a repeating timeout never lets it do.

Three candidates were considered for a fixed anchor instead:

A count of firings — track how many times the timeout has fired and stop
at N — was rejected as the wrong feature. The ask is a wall-clock deadline
("give up after 8 days"), not a firing budget ("give up after 4 reminders").
The two coincide only when nothing ever changes `fire_after`, `check_interval`
or the scheduler's polling cadence for the life of the record. A count would
need its own attribute (an integer, incremented on every fire) and is a
reasonable follow-up feature, but it answers a different question from the
one this PR was asked to answer.

`entered_current_state_at`, the calculation `workflow-history.md` already
computes for exactly this "state_entered_at lies about repeats" problem, was
also rejected. It reads the transition log and returns the `occurred_at` of
the most recent row where `from_state != to_state`, filtering out the very
rows a repeat writes, and reusing it would have meant no new attribute at
all. It cannot be filtered on, though:
`AshWorkflow.Verifiers.ValidateTimeoutFields.validate_calculation_is_expression/3`
already rejects any timeout `field` that is a module calculation rather than
an expression calculation, because the trigger's `where` clause is evaluated
by the data layer and a module calculation is computed in Elixir after the
read. `EnteredCurrentStateAt` is a module calculation — it queries the
transition log — so it hits exactly that rule. It would also make
the bound depend on `transition_log` being configured, which the ask
does not call for.

A second attribute, `repeat_started_at`, is what was built. Added only when
some timeout bounds its repeat without naming an anchor of its own
(`AshWorkflow.Transformers.AddAttributes.add_repeat_started_at/1`), it is
written to the same instant as `state_entered_at` on every genuine step entry
— a manual transition, an automatic step completing, a transition timeout, an
undo, the initial create — and left untouched by a repeat's own firing
(`AshWorkflow.Changes.RecordEvent`'s `repeat_fire?` option, `false` at every
entry site and `true` only where `AshWorkflow.Transformers.AddActions`
injects the action-timeout's own `RecordEvent`, and only when that firing
actually repeats). Being a plain column rather than a calculation, both
`AshWorkflow.Scheduler.Oban`'s trigger `where` and
`AshWorkflow.Scheduler.Precise`'s `Work.match` re-check can filter on it
directly, the same way they already filter on `state_entered_at`.

`AshWorkflow.Transformers.AddScheduler.repeat_until_match/2` folds the check
into `Work.match` as an extra clause:
`is_nil(anchor) or anchor > ago(until)`. Once
the anchor is further in the past than the bound, this clause is
false forever for the current step visit — the record never matches again
until it leaves and re-enters the step. Because both schedulers execute
through the same `Work.match`, correctness lives in exactly one place: even
though `AshWorkflow.Scheduler.Precise`'s recovery sweep arms timers from a
separate, narrower filter (`Precise.Timeline.due_records/3`), every timer —
swept or precisely armed — fires through `fire/4`, which re-reads the record
and re-checks the full `Work.match` before running anything. A bound-exceeded
record armed by an over-eager sweep therefore still fires nothing.

Left there, though, a bound-exceeded record would keep matching the sweep's
narrower filter forever, arming a timer on every `look_ahead_ms` tick that
`fire/4` immediately discards — one wasted read and one wasted timer per
record per tick, indefinitely, for every record that has run out its
reminders. `due_records/3` also filters on the bound now, checked
against "now" rather than the horizon's `cutoff`: a record already
bound-exceeded is excluded from the sweep outright, rather than merely from
running once armed.

`is_nil(repeat_started_at)` treats a record written before this attribute
existed — a new column on what may be an existing table — as "bound not yet
reached" rather than raising or refusing to poll it. Backing it with
`NOT NULL` and a migration that backfills every existing row from
`state_entered_at` was rejected: it assumes every existing row's current
`state_entered_at` already reflects a genuine entry rather than a stale
repeat reset, which is precisely the fact this attribute exists because
`state_entered_at` cannot be trusted to report. Leaving it permanently `nil`
was also rejected, once it was pointed out that "bound not yet reached"
would then mean "never bounded" for every record already repeating when
a bound was added to its timeout, the opposite of what enabling the
option asks for. `AshWorkflow.Changes.RecordEvent` instead backfills lazily:
a repeat fire that finds `repeat_started_at` still `nil` sets it to the
pre-firing `state_entered_at` — the last instant this repeat actually reset
the clock — rather than leaving it unset. That is the closest available
estimate of when repeating started, and it is only ever read once, on the
first repeat fire after the attribute exists; every fire after that finds it
already set and leaves it alone.

A fourth option, not a new attribute but a different one moved, would invert
which attribute a repeat writes: leave `state_entered_at` alone as the
genuine entry time, and have `repeat` write a new `last_fired_at` instead,
with `fire_after` measured against `coalesce(last_fired_at, state_entered_at)`.
That would make `state_entered_at` truthful again for every other deadline on
the step, and remove the reason `AshWorkflow.Calculations.EnteredCurrentStateAt`
exists at all. It was not taken because it changes the existing, released
`repeat` mechanism rather than adding beside it: every workflow already using
`repeat: true` measures `fire_after` against `state_entered_at`, and moving
that to a new column is a breaking change to a feature this PR was not asked
to touch. The bound adding a second attribute, rather than `repeat`
changing which attribute it uses, keeps this PR additive: a workflow that
declares no bound gets no new column and no behavior change at all.

## What happens when the bound is reached

Reaching the bound stops the repeat. It does not transition state, and it
runs no additional action.

A second option was considered: let the `repeat` block itself carry a
`transition_to`, so reaching the bound both stops the reminders and moves the
workflow along in one declaration. Rejected, because it duplicates a
mechanism that already exists and composes cleanly:

```elixir
step :awaiting_response do
  timeout :reminder do
    fire_after {2, :days}
    action :send_review_reminder

    repeat true do
      until {8, :days}
    end
  end

  timeout :give_up, fire_after: {8, :days}, transition_to: :escalated
end
```

`give_up` is an ordinary, non-repeating transition timeout — the same
mechanism `documentation/topics/timeouts-and-deadlines.md` already documents
under "Transition timeouts" — given a `fire_after` equal to the bound. It
needs no new field on `Entities.Timeout`, no new case in
`AshWorkflow.Transformers.AddScheduler`, and no new question about what
`transition_to` means when it is attached to a bound rather than to a
deadline. The two timeouts share nothing at runtime; they happen to agree on
one number, the same way `:warn` and `:breach` in the existing multi-timeout
example agree on nothing at all except both watching the same step.

The cost of this choice is that a workflow author writes the bound twice —
once on `until`, once on `give_up`'s `fire_after` — rather than once.
That is judged cheaper than a second, transition-shaped meaning for
the bound, and cheaper than teaching `AshWorkflow.Verifiers.ValidateTimeoutFields`
to reconcile the bound against a `transition_to` that lives on
the same entity.
