# Temporal resources × AshWorkflow — exploration notes

Branch: `explore-temporal`, rebased onto `main` 2026-09-11. Upstream is
unreleased: `temporal` branches on `ash` (`89fec87`, reporting v3.33.3),
`ash_sql` and `ash_postgres`. Requires PG19 beta, or `Ash.DataLayer.Ets`.

Read §13 and §14 first. They correct §3, §7 and §8, which were written before
any of this could be run.

Reference: https://github.com/ash-project/ash/blob/temporal/documentation/topics/advanced/temporal-resources.md

## 1. Version gating

`AshPostgres.DataLayer.Info.min_pg_version(resource)` → `repo.min_pg_version()`
(a `Version` struct; `AshPostgres.Repo.BeforeCompile` errors if undefined). So a
version check is available.

We shouldn't use it. The signal AshWorkflow cares about is
`Ash.Resource.Info.temporal?(dsl)`, not the PG version:

- `Ash.Resource.Verifiers.ValidateTemporal` already rejects a temporal resource
  on a data layer answering `Ash.DataLayer.can?(_, _, :temporal) == false`.
- `AshPostgres.Verifiers.VerifyTemporal` already requires `btree_gist` in
  `installed_extensions/0`.

Branching on `temporal?` also covers the ETS data layer without extra configuration, which is how the
demos/tests would run without a PG19 build. Policing the server version is
upstream's job, and today it's soft anyway — a temporal resource on PG18
compiles and fails at migrate time.

Conclusion: **every transformer branch keys off `temporal?`, never a version.**

## 2. AshOban interaction

From `deps/ash_oban/lib/transformers/define_schedulers.ex`:

- Scheduler: read action → `Ash.Query.do_filter(trigger.where)` →
  `Ash.Query.select(primary_key)` → one job per primary key.
- Worker: re-read filtered by that PK, optional `Ash.Query.lock(:for_update)`,
  `Ash.Changeset.filter(changeset, primary_key)`, `TriggerNoLongerApplies` if it
  no longer matches.

What survives unchanged:

- **The PK round-trip.** `Ash.Resource.Transformers.AddPeriodAttribute` adds the
  period as a plain attribute with `generated?: true` — it is *not* in Ash's
  `primary_key`. Postgres has the composite `(id, valid_at WITHOUT OVERLAPS)` PK;
  Ash still sees `[:id]`. So job args stay `%{id: ...}` and the worker's re-read
  resolves to the currently-valid version, which is exactly what a timeout wants.
- **`where` clauses.** Reads default to `as_of: now()` and `now()`/`ago()` inside
  a filter anchor to the query's `as_of`, so trigger filters keep their meaning.

What needs work:

- **`as_of` is not threaded through AshOban.** Nothing in ash_oban knows the
  concept. Scheduler read and worker write each default to their own wall clock.
  Today that drift is invisible; with temporal it is written into the period
  boundary — a job retried an hour later stamps the transition at retry time, not
  at the deadline. Fixing it means carrying `as_of` in the job args and passing it
  as the **action option** (required: cascades / `manage_relationship` /
  identity pre-checks run during changeset construction). This is an upstream
  ash_oban ask, same shape as its existing actor/tenant persistence.
- **`lock_for_update?`.** Confirm `data_layer_can?({:lock, :for_update})` still
  holds on the temporal branch, and that a held row lock co-operates with
  `UPDATE ... FOR PORTION OF` (which splits the locked row into two).
- **Staleness becomes louder.** A write whose `as_of` lands where no version is
  valid is refused as stale. A backdated retry after a human already transitioned
  the workflow would raise rather than no-op. Arguably correct; needs classifying.

## 3. DSL implications

### `state_entered_at` stays — corrected 2026-09-11

An earlier draft of this section said to drop the `state_entered_at` injection
in `transformers/add_attributes.ex`, drop the
`set_attribute(:state_entered_at, &DateTime.utc_now/0)` calls on the five
transition sites in `add_actions.ex`, and default the timeout `field:` to
`lower(valid_at)`. **That was wrong, and §13 has the measurement.**

`lower(valid_at)` is the instant *this version* was written, not the instant the
state was entered. Every update splits the period, including an update that
changes no state, so an unrelated edit moves the lower bound and silently
re-arms every timeout anchored on it.

So on a temporal resource:

- **Keep the `state_entered_at` attribute.** It is the only thing that tracks
  state entry, exactly as on a non-temporal resource.
- **Keep the five `set_attribute` calls**, but set them from the changeset's
  `as_of` rather than `&DateTime.utc_now/0`. The wall clock and the period
  would otherwise disagree on a backdated transition — that part of the original
  note stands, it is the conclusion drawn from it that does not.
- **The timeout `field:` default stays `state_entered_at`.**

What temporal removes from AshWorkflow is not the anchor. It is the
point-in-time read and the aggregate in §6.

### `repeat: true` — not broken, but noisier

An earlier draft claimed this was the one thing temporal genuinely breaks, on the
reasoning that a repeat changes no state, so no new period is written, so
`lower(valid_at)` never moves and the timeout re-fires forever. Both halves are
wrong. Every update splits the period whether or not `state` changed (§13), and
the anchor was never `lower(valid_at)` to begin with.

Repeating timeouts reset `state_entered_at`
(`add_actions.ex:inject_repeating_timeout_changes`) and that keeps working
unchanged on a temporal resource.

What is genuinely different is cost, not correctness. Each reset writes a new
version, so a 2-day reminder across a 9-day state leaves four extra versions
whose only difference is the anchor. Reads stay correct. The history gets harder
to read, which is the `rows written` row in §14.

### Relationships

`workflows-and-relationships.md` needs revisiting: a `belongs_to` across a
temporal boundary needs `temporal_keys`, `has_one`/`has_many` need
`no_attributes? true`, and PERIOD FKs only support `NO ACTION` — all cascades
move into the application.

### No new DSL surface

Infer from `Ash.Resource.Info.temporal?/1`. A `workflow do temporal? true end`
flag would just be a second source of truth.

## 4. The sharp limitation

No all-history reads. Every read is one instant; querying across a record's
periods is unsupported. So the workflow *timeline* ("every state this instance
passed through") still needs a transition log. Temporal gives point-in-time
reconstruction, not an audit trail — the distinction to make on stage.

## 5. Open questions to test

- Does `Ash.Query.lock(:for_update)` + `FOR PORTION OF` behave under concurrency?
- Does ash_state_machine's transition validation interact with a period split?
- Does an `as_of`-carrying Oban job survive the `TriggerNoLongerApplies` path?
- What does `mix ash_postgres.generate_migrations` emit for a workflow resource?
- Answered in §13: does `lower(valid_at)` track state entry? It does not.

## 6. Relationship to the transition-log branch (`.wt/feat/transition-history`)

The two features answer different questions and do not overlap much:

| | transition log | temporal |
|---|---|---|
| state at instant `t` | yes (`state_at/2`) | yes |
| **full row** at instant `t` | no — log holds from/to/name/occurred_at/triggered_by only | yes |
| timeline ("how did it get here") | yes | **no** — no all-history reads |
| causality: `triggered_by`, actor FK | yes | no |
| "how many in `:awaiting_review` on date X" | non-portable `DISTINCT ON`, documented not shipped | `Ash.count(filter(state == :awaiting_review), as_of: t)` — one indexed query |

That last row is where temporal earns its place: the aggregate query
`workflow-history.md` explicitly gives up on is one indexed read under temporal.

If both ever ship, `state_at/2` stays the log's implementation — portable, and it
carries `triggered_by`.

## 7. Implementing `repeat`

`workflow-history.md` already did the conceptual work by splitting the **timer
anchor** from **state entry**.

The original framing here assumed `lower(valid_at)` *is* `entered_current_state_at`
on a temporal resource, so that only `repeat` needed an anchor elsewhere. §13
measured that assumption and it is false: the period tracks the last write, so
`lower(valid_at)` is not the anchor for a repeating timeout *or* a one-shot one.
`state_entered_at` stays either way, per §3.

That removes the reason `repeat` was special. It re-arms by moving its anchor,
exactly as it does on a non-temporal resource, and the only remaining question is
what the period churn costs. Options:

1. **Anchor column on the workflow row.** Every anchor write splits the period. A
   2-day reminder across a 9-day state yields four extra versions with identical
   `state`. Reads stay correct and the anchor stays honest, because the anchor is
   its own column rather than the period. The cost is table growth and a history
   full of versions that differ only in a timer field.
2. **Anchor on a non-temporal 1:1 companion row.** Keeps the trigger `where` a plain
   indexed comparison (the doc's stated reason for not using an aggregate), no period
   churn. Cost: another table to keep in step.
3. **Self-rescheduling Oban job — preferred.** `AshOban.build_trigger/3` splits off
   `:actor/:tenant/:args/:action_arguments` and passes the rest to `Oban.Worker.new/2`,
   so `AshOban.run_trigger(record, :reminder, schedule_in: n)` works. The repeat re-arms
   by enqueuing its next occurrence rather than moving a timestamp so a poll re-matches.
   No anchor, no period churn, no log dependency, identical behaviour on temporal and
   non-temporal resources, and repeats drop out of the per-tick polling cost that the
   `check_interval` docs warn about.

   Fiddly bits to verify:
   - The generated worker is built with `unique: [period: :infinity, states: [...]]`
     keyed on job args (which include `primary_key`). Enqueuing the next occurrence
     from inside the executing job would dedupe against itself. Needs
     `replace: [:scheduled_at]`, an explicit `unique: [keys: [:primary_key]]`, or an
     enqueue after completion.
   - Cancellation on state change: the worker already raises `TriggerNoLongerApplies`
     when the record stops matching the trigger's `where`, so a stale scheduled repeat
     self-cancels — confirm that discards rather than retry-storms.

   Consequence worth thinking about: the `repeat: true` + custom `field:` prohibition
   exists because resetting a custom field lies about the data. If repeats reschedule
   instead of resetting, there is nothing to lie about and the combination becomes
   coherent.

Option 3 makes `repeat` honest independent of temporal — worth doing on the
transition-history branch regardless.

## 8. Decision: withdrawn — temporal repeats do not require the transition log

**Superseded by §13.** This section concluded that a temporal resource must carry
a transition log before `repeat: true` is allowed, and specified a verifier to
enforce it. The whole argument rested on `lower(valid_at)` being the state-entry
anchor, which left a repeat with nowhere to record when it last fired. §13 shows
the period was never the anchor, so `state_entered_at` is present on temporal
resources too and a repeat re-arms against it exactly as it does today.

Consequences:

- **Do not build the verifier.** `temporal? and repeat: true and no transition_log`
  is not an error. There is nothing to enforce.
- **No coupling** between the timeout feature and the transition log. They stay
  independent, which is what §6 wanted anyway.
- The self-rescheduling design below is still worth doing, but on its own merits
  (it drops repeats out of per-tick polling), not because temporal forces it. It
  applies equally to non-temporal resources.

The original text follows, kept for the reasoning about reconcilers.

Chosen shape (option A + option 3 from §7):

- **Non-temporal resources keep today's mechanism unchanged.** `state_entered_at`
  as a poll anchor is fine when a write doesn't split a period. No reconciler, no
  coupling, no new surface. `repeat: true` continues to work with zero setup.
- **Temporal resources** re-arm by self-rescheduling
  (`AshOban.run_trigger(record, name, schedule_in: ...)`, inserted in the same
  transaction as the effect), plus a low-frequency reconciler to repair dropped
  chains.
- The reconciler is a **plain AshOban trigger**, not a hand-written worker:
  `where: first(log.occurred_at) <= ago(duration)`, running hourly rather than on
  `check_interval`. Pure Ash, portable to ETS, no `oban_jobs` introspection.
  The doc's objection to that aggregate is a per-minute-polling objection; at
  hourly reconciliation it does not bite.
- Therefore, on a temporal resource, the transition log is the **only** thing that
  knows when the timer last fired — hence the verifier.

Rejected: a second `oban_jobs`-based reconciler ("is a job pending" rather than
"is a repeat due"). It avoids the coupling and needs no anchor, but `oban_jobs` is
not an Ash resource, so it cannot be a trigger `where` — it means a hand-written
worker that is Postgres/Oban-specific and untestable on ETS. Two reconciler
implementations is too much surface for a feature gated on a beta database. If it
is ever built it relaxes the verifier, which is the easy direction to move in.

### The verifier

```
temporal?(resource) AND any timeout has repeat: true AND no transition_log
  -> DslError
```

Home: `lib/ash_workflow/verifiers/validate_timeout_fields.ex` — it already
reasons about `repeat` in combination with `field:`. Message should point at
`mix ash_workflow.gen.transition_log` and say why: on a temporal resource the
period's lower bound tracks state entry, not timer firings, so the log is the
only durable anchor.

Per `CONTRIBUTING.md`, the new constraint needs a `usage-rules.md` mention or
`test/documentation_drift_test.exs` fails the build.

### Not landable yet

The verifier's condition calls `Ash.Resource.Info.temporal?/1`, which only exists
on the `temporal` branch. Nothing here can compile against released Ash, so this
section stays a design record until temporal merges.

## 9. Result of actually trying it (2026-08-27)

Pointed `mix.exs` at the three `temporal` branches (`ash`, `ash_sql`,
`ash_postgres`, all `override: true`) on Elixir 1.19.1 / OTP 28.

**AshWorkflow compiles, and a temporal workflow resource compiles — but nothing
runs.** Two independent breakages, both from the same root cause, neither of them
anything to do with the design in §1–8.

### Root cause: the temporal branch inverts Spark's transformer sort

Ash's `temporal` branch adds two transformers —
`Ash.Resource.Transformers.AddPeriodAttribute` and
`Ash.Resource.Transformers.AddTemporalRelationshipFilters`. Their presence flips
the topological order of *unrelated* third-party extension transformers, so
declared `before?`/`after?` constraints are silently violated.

Minimal reproduction, on an existing (non-temporal) test resource:

```elixir
all = Spark.extensions(AshWorkflowTest.ApprovalWorkflow) |> Enum.flat_map(& &1.transformers())
new = [Ash.Resource.Transformers.AddPeriodAttribute,
       Ash.Resource.Transformers.AddTemporalRelationshipFilters]

Spark.Dsl.Transformer.sort(all)
# AshStateMachine.Transformers.AddState                 -> index 0
# AshStateMachine.Transformers.FillInTransitionDefaults -> index 21

Spark.Dsl.Transformer.sort(Enum.reject(all, & &1 in new))
# AshStateMachine.Transformers.AddState                 -> index 24
# AshStateMachine.Transformers.FillInTransitionDefaults -> index 16
```

Removing just those two entries restores the correct order. Same measurement for
our own constraint: on `main`, `AddObanTriggers` sorts at 2 and
`AshOban.Transformers.SetDefaults` at 28; on `temporal`, 7 and 1 — inverted,
despite `AddObanTriggers.before?(AshOban.Transformers.SetDefaults) == true`.

### Symptom 1 — AshOban trigger defaults are dropped

`SetDefaults` runs before AshWorkflow has added any triggers, so every generated
trigger keeps `read_action: nil` and `scheduler_queue: nil`. `test_helper.exs`
dies before a single test runs:

```
** (RuntimeError) Must configure the queue `:`, required for
the scheduler of the trigger `:__timeout_trigger_review_escalation`
```

### Symptom 2 — the state machine has no initial state

`AshStateMachine.Transformers.AddState` runs at index 0, before the state machine
has been built, so the `state` attribute is created with `default: nil`. Every
create fails with `attribute state is required`. On `main` the same attribute has
`default: :review`.

### Also: cold full compiles of `ash` fail

```
** (UndefinedFunctionError) function Ash.Resource.Validation.Changing.Opts.docs/0
   is undefined ... lib/ash/resource/validation/builtins.ex:49
```

`changing.ex` and `builtins.ex` are byte-identical to `main`, and `main` compiles
cleanly, so this is another ordering effect. Workaround used here: compile `ash`
at `main` once, then `git -C deps/ash checkout origin/temporal` and recompile
incrementally.

### Verdict

Nothing in §1–8 was tested, because the branch cannot get far enough to test it.
All three are upstream bugs worth reporting — the sort inversion in particular
would break *any* extension that integrates with AshOban or ash_state_machine, not
just this one. Re-run this probe once they are fixed; the design work stands
unchanged in the meantime.

## 10. Who is working on it, and where the sort bug actually lives

### Upstream activity

`matt-beanland` is driving it, Zach Daniel reviewing and merging. 16 commits on
`ash`'s `temporal` branch that aren't on `main` (12 Matt, 4 Zach), the feature
commit dating to 2026-06-29 and a burst of work 2026-08-17→24 across `ash`,
`ash_sql`, `ash_postgres`. Recent merged PRs: ash #2896–#2902, ash_sql #256,
ash_postgres #818/#838/#839/#840. No open temporal PRs. Notably ash_postgres
**#839 is "fix: order temporal migration operations under the toposort"** — they
have already been bitten by toposort ordering once on this branch.

### Root cause, minimised to five transformers

Greedy minimisation of the 32-transformer list gives:

```
AshWorkflow.Transformers.AddObanTriggers          -- before?(SetDefaults) = true
AshOban.Transformers.SetDefaults                  -- after?(_) = true
AshStateMachine.Transformers.AddState             -- before?(DefaultAccept) = true, after?(_) = true
Ash.Resource.Transformers.DefaultAccept
Ash.Resource.Transformers.AddTemporalRelationshipFilters  -- after?(DefaultAccept) = true   <-- new on the branch
```

sorting to `AddState, SetDefaults, AddObanTriggers, DefaultAccept, ATRF` — with
`AddObanTriggers` *after* `SetDefaults`, violating its declared `before?`.

The edges form a cycle:

```
AddState --before--> DefaultAccept --> ATRF --(after?(_)=true on AddState)--> AddState
```

`AddTemporalRelationshipFilters.after?(DefaultAccept) -> true` is the new edge
that closes the loop against `AddState`'s catch-all `after?(_) -> true`. Once the
graph is cyclic, `Spark.Dsl.Transformer.walk_rest/3` leaves its clean path — and
its two fallback branches **append** to the accumulator (`acc ++ [vertex]`) where
the acyclic branch **prepends** (`[vertex | acc]`), with a single
`Enum.reverse/1` at the end. So a cycle anywhere reverses the emission order of
constraints that have nothing to do with it.

### The naive fix does not work

Making both fallback branches prepend fixes our violation on the full list
(`violated? false`), but then breaks `SetDefaults.before?(DefineSchedulers)`:

```
** (RuntimeError) Exception in transformer AshOban.Transformers.DefineSchedulers
No configuration for `domain` present on BasicWorkflow.DocumentApproval
```

So the asymmetry is load-bearing, not simply inverted. A real fix has to detect
the cycle, break only edges *inside* it, topsort the remainder, and report a
warning instead of silently reordering. Two candidate homes:

- **spark** — `walk_rest/3` degrading incoherently on a cyclic graph.
- **ash (temporal branch)** — narrowing `ATRF.after?(DefaultAccept)` so the loop
  never forms.

### Why no test caught it

- **ash's suite structurally cannot.** The cycle needs `ash` plus
  `ash_state_machine` *and* `ash_oban` in one resource; ash depends on neither.
- **spark has exactly one ordering test** — `test/persister_sort_test.exs`, three
  transformers, acyclic, no catch-all `after?(_) -> true`. It covers the happy
  path only.
- Nothing anywhere pins ordering in the presence of a catch-all or a cycle.

Which is the argument for the regression test: an ordering contract that
`ash_state_machine` and `ash_oban` both depend on, that any new Ash transformer
can silently break, and that no suite currently asserts. The five-module set above
is small enough to be that test, in spark, with no Ash dependency — recreate the
same `before?`/`after?` shapes with dummy modules and assert the declared pairs
hold.

## 11. The regression test

Two artifacts, both on released deps so they are mergeable as-is:

- `test/ash_workflow/transformer_ordering_test.exs` — asserts every `before?/1`
  we declare against AshOban / ash_state_machine is honoured, plus the two facts
  that depend on it (triggers have `read_action` and `scheduler_queue`; `state`
  defaults to the initial step).
- `bin/check-transformer-ordering.exs` — the same contract check across every
  test-domain resource, via `mix run`, with no ExUnit. Needed because a broken
  ordering stops `test/test_helper.exs` booting (AshOban raises on the
  unconfigured queue before ExUnit starts), so the suite cannot report the very
  failure the test exists to catch.
- `test/support/transformer_contracts.ex` — the contract list, shared by both.

Validated both ways:

| | test | script |
|---|---|---|
| `ash` main | 3 tests, 0 failures | `transformer ordering OK across 21 resources`, exit 0 |
| `ash` temporal | suite cannot boot | 189 violations, exit 1 |

To reproduce the temporal run, pin in `mix.exs` (all three need `override: true`):

```elixir
{:ash, github: "ash-project/ash", branch: "temporal", override: true},
{:ash_sql, github: "ash-project/ash_sql", branch: "temporal", override: true},
{:ash_postgres, github: "ash-project/ash_postgres", branch: "temporal", override: true, only: [:dev, :test]},
```

and work around the cold-compile failure in §9 by compiling `ash` at `main`
first, then `git -C deps/ash checkout origin/temporal && mix deps.compile ash`.

## 12. Standalone reproduction, and how to fix it

`.claude/plans/spark-sort-repro.exs` reproduces the whole thing with five dummy
transformers and **no Ash dependency** — released spark alone. It mirrors the real
`before?`/`after?` tables of `AddObanTriggers`, `AshOban.SetDefaults`,
`AshStateMachine.AddState`, `Ash.Resource.Transformers.DefaultAccept`, and
`AddTemporalRelationshipFilters`:

```
MIX_ENV=test mix run .claude/plans/spark-sort-repro.exs

without ATRF          : AddObanTriggers=0 SetDefaults=3 -> OK
with ATRF (as-is)     : AddObanTriggers=2 SetDefaults=1 -> VIOLATED
with ATRF narrowed    : AddObanTriggers=0 SetDefaults=4 -> OK
```

The unrelated pair inverts purely because a fifth transformer closes a cycle
elsewhere in the graph.

### Fix in spark (the class of bug)

`Spark.Dsl.Transformer.sort/1` builds a `:digraph` and walks it in
`walk_rest/3`. The acyclic branch **prepends** each source vertex
(`[vertex | acc]`); both fallback branches, taken once no source vertex exists,
**append** (`acc ++ [vertex]`), and the whole accumulator is reversed at the end.
So the moment a cycle appears, vertices emitted through the fallbacks land at the
opposite end from where the walk intended, dragging satisfied constraints with
them.

Symmetrising the fallbacks to prepend does clear our violation on the full
32-transformer list, but then breaks `SetDefaults.before?(DefineSchedulers)`
(`No configuration for domain present on BasicWorkflow.DocumentApproval`), so the
asymmetry is load-bearing rather than simply backwards. The principled fix:

1. Detect the cycle (`:digraph_utils.is_acyclic/1`, or
   `:digraph_utils.cyclic_strong_components/1` for the specific vertices).
2. Break edges only *within* the offending strong component, leaving every other
   edge intact, then `:digraph_utils.topsort/1` the result.
3. Warn, naming the cycle. Silently reordering unrelated transformers is what made
   this cost a day; a warning would have named the culprit immediately.

Add spark's regression test alongside `test/persister_sort_test.exs`, which today
covers three transformers, acyclic, with no catch-all `after?(_) -> true`. The
five-module model above is the missing case.

### Fix in ash (this instance)

`AddTemporalRelationshipFilters.after?(Ash.Resource.Transformers.DefaultAccept)`
is the edge that closes the loop against `AddState`'s catch-all
`after?(_) -> true`. The model above shows dropping it clears the violation.
Worth asking whether it is needed at all: the transformer adds relationship
filters, `DefaultAccept` computes action accept lists, and the two look
independent — the sibling `after?(SetRelationshipSource)` is the one doing real
work. If it is needed, it can likely be narrowed to the specific transformer
whose output it reads rather than `DefaultAccept` wholesale.

This is worth landing regardless of the spark fix: it unblocks the temporal
branch now, and the spark fix stops the next transformer from doing the same
thing.

## 13. What the period actually anchors, measured (2026-09-11)

Re-ran the probe after the rebase onto `main`. `ash_state_machine` 0.2.12 removed
the catch-all `after?(_)` that was closing the cycle in §10, so the suite now runs
against the stock `temporal` branch with no patched deps: `transformer ordering OK
across 51 resources`, `715 tests, 0 failures`.

That made it possible to test §3's central claim for the first time.

### The measurement

A temporal resource on `Ash.DataLayer.Ets` with `AshStateMachine`, carrying
`state` and an unrelated `notes` attribute. Three writes, each with an explicit
`as_of`:

| write | `state` after | `valid_at` of the current version |
|---|---|---|
| create at `t0`, enters `:review` | `:review` | `[t0, ∞)` |
| `add_note` at `t1` — **no state change** | `:review` | `[t1, ∞)`, and `t0`'s version truncated to `[t0, t1)` |
| `reject` at `t2` | `:rejected` | `[t2, ∞)` |

An update that touched only `notes` moved the lower bound from `t0` to `t1` while
`state` stayed `:review`.

### What it means

`lower(valid_at)` answers "when was this version written", not "when was this
state entered". The two coincide only on a resource whose sole writes are
transitions, which is not a constraint AshWorkflow imposes or should impose.

A 30-minute review timeout anchored on `lower(valid_at)` is re-armed by anybody
adding a note. The timeout never fires, and nothing reports it. This is the same
failure the `field:` docstring already describes for resetting an arbitrary field
— it just arrives through the storage layer rather than through the DSL.

The docs state it plainly, and the measurement agrees: "**An update splits the
period.**" There is no qualification about which attributes changed.

### Naming

`state_valid_at` was considered as a rename and rejected. `valid_at` names
row-version validity in Ash's temporal vocabulary, so `state_valid_at` reads as a
second period over the state rather than a timestamp, which is not what it is and
not something the data layer offers. `state_entered_at` already says what it holds.

## 14. The verdict: it depends, and on what

Neither mechanism dominates. They record different things, and the deciding
question is whether the reader needs **values** or **events**.

| | transition log | temporal |
|---|---|---|
| state at instant `t` | yes, `state_at/2` | yes |
| **full row** at instant `t` | no — from/to/name/occurred_at/triggered_by only | **yes** |
| whole timeline in one query | **yes**, ordered | no — every read is one instant |
| why it moved: `triggered_by`, actor | **yes** | no |
| how many in state X on date Y | non-portable `DISTINCT ON` | one indexed read |
| rows written | one per transition | one per **update**, transition or not |
| timer anchor | `state_entered_at` | `state_entered_at` — unchanged, per §13 |
| data layer | any | PG19 beta, or non-transactional ETS |
| ships | now | when PG19 does |

Two rows carry the decision. Temporal reconstructs the **whole record** and the
log cannot. The log reconstructs the **sequence and its causes** and temporal
cannot.

The `rows written` row is the one that is easy to miss. A temporal workflow row
accumulates a version for every edit, so a record touched often has a history
dominated by versions whose `state` never changed. That is exactly right for
reconstructing values and actively unhelpful for reading a state history.

### A use case for each

Temporal wins when the question is what a person saw. A reviewer approved a
candidate at 14:02 and the decision is later challenged. The question is not
which states the record passed through, it is what the record *said* at that
instant — every field, plus whatever the loaded relationships said, because
`as_of` propagates through them. One read answers it, and the answer is
internally consistent rather than assembled from a log plus assumptions about
what else had changed by then.

The log wins when the question is how something took nine days. An application sat in
`:review` far past its SLA. The question is the sequence and its causes: when it
entered `:review`, whether it bounced back from `:interview` and how many times,
which escalation timeout fired, and who or what performed each move. That is one
ordered read of the log. Under temporal it is a guess at sampling instants, and
even with perfect sampling the `triggered_by` and actor are simply not recorded.

Stated as a pair of questions: *"what did it look like?"* is temporal, *"how did
it get here?"* is the log.

### Consequence for the roadmap

They are complementary, and neither supersedes the other. A resource wanting both
should have both — temporal costs no extra table and the log stays portable and
carries causality. `state_at/2` remains the log's implementation even on a
temporal resource, because it carries `triggered_by` and temporal does not.

## 15. Answering the two objections to §14 (2026-09-11)

Both were raised against §14's claim that temporal cannot produce a timeline.
Both are largely right, and §14 overstated the limitation.

### `triggered_by` on the row works

Nothing stops a temporal resource carrying its own causality. Add
`triggered_by` as an ordinary attribute, accept it on every transition action,
and each version records who or what caused the state it holds. Measured on ETS:

```
~U[09:00] -> ~U[10:00]  state=:review     by="applicant"
~U[10:00] -> ~U[11:00]  state=:review     by="recruiter:kim"
~U[11:00] -> ~U[12:00]  state=:interview  by="recruiter:kim"
~U[12:00] -> open       state=:rejected   by="timeout:escalation"
```

So "temporal does not record causality" was wrong. It does not record it *for
you*, which is a different claim. The log's advantage here is that the column
and its actor FK are generated rather than hand-maintained.

### The timeline is reachable, in N+1 queries

There is genuinely no all-history read. Measured: a read with no `as_of`, and a
read with `as_of: :now`, both return exactly one row.

But each returned version carries its **own** `valid_at.upper`, so the chain can
be walked without guessing instants. Read `as_of` the first instant, take that
version's `upper`, read `as_of` that, repeat until `upper` is nil:

```
recovered 4 versions in 5 queries
```

That is deterministic traversal, not sampling. §4 and §14 both called a timeline
under temporal "sampling", and that was wrong — you never have to guess where to
look, because every version names its own end.

What it costs is a query per version and a client-side loop, against one ordered
read for the log. On Postgres the walk is N round trips.

### What survives of the distinction

The noise is the durable part. In the run above:

```
4 versions, but only 2 were state changes
```

Every write splits the period, so reconstructing the *state* history means
walking every version and diffing consecutive `state` values. The log stores only
transitions, so it never has to. The gap widens with every non-transition edit —
a record with 200 note edits and 3 transitions needs 201 queries and a diff to
find the 3.

So the corrected distinction is not "can it" but "at what cost":

| | transition log | temporal |
|---|---|---|
| full timeline | one ordered read | N+1 reads, walking `upper` |
| causality | generated `triggered_by` + actor FK | hand-rolled attribute |
| transitions only | stored that way | diff consecutive versions |
| full row at instant `t` | no | one read |

Temporal can do everything the log can, with more queries and more hand-rolling.
The log cannot reconstruct the full row at an instant at all. That asymmetry, not
capability, is the honest ending.

## 16. The escape hatch: a manual read returns every version in one query

§15 said the timeline costs N+1 queries. That is true only of generated read
actions. A manual read action returns the whole history in one.

The `as_of` filter is applied *by the data layer*, and a manual read never
invokes it. The docs say as much, in a bullet aimed at writes: "**Manual actions
bypass temporal handling** — the data layer is never invoked, so it's on you to
manage periods."

```elixir
defmodule AllVersions do
  use Ash.Resource.ManualRead

  def read(ash_query, _ecto_query, _opts, _context) do
    query = Ash.DataLayer.Ets.resource_to_query(ash_query.resource, ash_query.domain)
    # never calling Ash.DataLayer.set_as_of/3
    Ash.DataLayer.Ets.run_query(query, ash_query.resource)
  end
end

read :all_versions do
  manual AllVersions
end
```

Measured on ETS against the temporal branch:

```
ordinary read (as_of defaults)     1 row
manual read, as_of never set       4 rows — ONE query

  09:00 -> 10:00  state=:review     by="applicant"
  10:00 -> 11:00  state=:review     by="recruiter:kim"
  11:00 -> 12:00  state=:interview  by="recruiter:kim"
  12:00 -> open   state=:rejected   by="timeout:escalation"
```

Full `Ash.Resource` structs, with `valid_at` populated, sortable and filterable
like any other attribute.

### On Postgres — reasoned, not measured

No PG19 build here, so this part is argument rather than result. It should hold
more firmly than on ETS: the table physically stores every version under
`PRIMARY KEY (id, valid_at WITHOUT OVERLAPS)`, and `as_of` is a `WHERE` clause
that `ash_sql` adds. A manual read that builds its own Ecto query, or a plain
`Ecto.Adapters.SQL.query!/3`, never gets that clause and sees all versions.
Ordering by `lower(valid_at)` is then an ordinary indexed sort. Worth confirming
on a real PG19 build before relying on it.

### What it costs

- **Unsupported.** The docs name this as a hole, not a feature. Nothing promises
  the signature of `run_query/2` or that a manual read keeps bypassing the filter.
- **Data-layer specific.** The module above names `Ash.DataLayer.Ets`. A Postgres
  version is a different module, so the portability argument for the log stands.
- **`as_of` no longer propagates** into that read's relationships, calculations or
  aggregates. You are outside the mechanism that makes time travel consistent.
- **Reads only.** A manual *write* means managing periods by hand, which is where
  the docs' warning actually bites. Do not.

### What survives, finally

Capability is no longer the distinction, and neither is query count:

| | transition log | temporal + manual read |
|---|---|---|
| full timeline | one ordered read | one read |
| causality | generated, with actor FK | an attribute you maintain |
| transitions only | stored that way | **diff every version** |
| full row at instant `t` | no | one read |
| portable across data layers | yes | no — one module per data layer |
| supported | yes | explicitly not |

Two things are left, and they are the honest ones. Temporal stores a version per
*write*, so finding state changes means diffing consecutive versions however you
fetch them. And the log is generated and portable where the escape hatch is
hand-rolled and outside the contract.
