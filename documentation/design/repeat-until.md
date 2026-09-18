# Bounding a repeat

## The question

`repeat: true` fires a timeout forever. The ask: give it a wall-clock ceiling —
"remind every 2 days, but give up after 8" — spelled as a duration tuple
alongside `repeat`, the way `fire_after` already is.

Two things need deciding: the exact DSL spelling, and what the bound is
measured against. The second turned out to be the whole problem.

## The DSL spelling

Two shapes were on the table:

```elixir
# A. A separate option
timeout :reminder, fire_after: {2, :days}, repeat_until: {8, :days}, ...

# B. `repeat` grows from a boolean into a boolean-or-keyword
timeout :reminder, fire_after: {2, :days}, repeat: [until: {8, :days}], ...
```

(A) won. `repeat` stays a plain boolean, which is what every existing
workflow already declares and what `AshWorkflow.Transformers.AddActions`
already reads to decide whether an action resets `state_entered_at`. Growing
it into `{:or, [:boolean, :keyword]}` would mean every reader of `timeout.repeat`
gaining a second shape to match on, for a feature only some timeouts use.
`repeat_until` sits next to `repeat` the same way `check_interval` sits next
to `fire_after` — a separate, optional duration.

`repeat_until` implies `repeat: true`
(`AshWorkflow.Entities.Timeout.normalize/1`, run as the entity's `transform`
at DSL-build time, before any transformer or verifier reads `repeat`), so
`repeat_until` alone is enough — it does not need to be declared alongside
`repeat: true`. The alternative, requiring both and rejecting `repeat_until`
without `repeat: true` as a compile error, was tried first: it kept `repeat`
as a single source of truth for whether the timeout loops, at the cost of one
extra line on every use. Implying it removes the boilerplate; `repeat_until`
has no meaning without repeating, so there is nothing ambiguous being
inferred, only a redundant declaration being made optional.

## What the bound is measured against

This is the part that is not a one-liner.

A repeating timeout works by resetting `state_entered_at` (or a custom
`field`) to now, every time it fires — that reset is the entire mechanism,
documented in `AshWorkflow.Entities.Timeout`'s moduledoc and
`usage-rules/timeouts.md`. It is why the trigger's `where` clause,
`field <= ago(fire_after)`, starts matching again 2 days after the last
firing rather than never matching again.

A bound checked against that same field can never be reached. Every firing
pushes `field` back to "now", so `field <= ago(repeat_until)` is exactly as
false immediately after a repeat as it is right after the record first
entered the step. The bound would need the record to sit still for
`repeat_until` — the one thing a repeating timeout never lets it do.

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
`repeat_until` depend on `transition_log` being configured, which the ask
does not call for.

A second attribute, `repeat_started_at`, is what was built. Added only when
some timeout in the workflow declares `repeat_until`
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
`is_nil(repeat_started_at) or repeat_started_at > ago(repeat_until)`. Once
`repeat_started_at` is further in the past than `repeat_until`, this clause is
false forever for the current step visit — the record never matches again
until it leaves and re-enters the step. Because both schedulers execute
through the same `Work.match`, the bound is enforced in exactly one place:
`AshWorkflow.Scheduler.Precise`'s recovery sweep arms timers from a separate,
narrower filter for performance (`Precise.Timeline.due_records/3`), but
every timer — swept or precisely armed — fires through `fire/4`, which
re-reads the record and re-checks the full `Work.match` before running
anything. A bound-exceeded record armed by an over-eager sweep therefore
still fires nothing.

`is_nil(repeat_started_at)` treats a record written before this attribute
existed — a new column on what may be an existing table — as "bound not yet
reached" rather than raising or refusing to poll it. The alternative, backing
it with `NOT NULL` and a migration that backfills every existing row from
`state_entered_at`, was rejected: it assumes every existing row's current
`state_entered_at` already reflects a genuine entry rather than a stale
repeat reset, which is precisely the fact this attribute exists because
`state_entered_at` cannot be trusted to report.

## What happens when the bound is reached

Reaching `repeat_until` stops the repeat. It does not transition state, and it
runs no additional action.

A second option was considered: let `repeat_until` itself carry a
`transition_to`, so reaching the bound both stops the reminders and moves the
workflow along in one declaration. Rejected, because it duplicates a
mechanism that already exists and composes cleanly:

```elixir
step :awaiting_response do
  timeout :reminder, fire_after: {2, :days}, action: :send_review_reminder, repeat_until: {8, :days}
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
once on `repeat_until`, once on `give_up`'s `fire_after` — rather than once.
That is judged cheaper than a second, transition-shaped meaning for
`repeat_until`, and cheaper than teaching `AshWorkflow.Verifiers.ValidateTimeoutFields`
to reconcile `repeat_until`'s bound against a `transition_to` that lives on
the same entity.
