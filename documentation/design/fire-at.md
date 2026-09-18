# Design: fire_at

Status: implemented.

## The problem

A timeout measures a duration from an anchor. `timeout :nudge, fire_after: {3, :days}, field: :last_session_date, action: :remind` reads `field` as the anchor and `fire_after` as the offset.

A field often holds the deadline itself rather than an anchor: `next_check_at`, `expires_at`, `committed_by_date`. What the author wants there is "fire once that instant has passed", which is an offset of zero. `AshWorkflow.Duration.validate/1` requires a positive integer, so zero cannot be written, and the idiom became `fire_after: {1, :seconds}` as a sentinel. `AshWorkflow.Verifiers.ValidateTimeoutPrecision` carried a paragraph in its error message coaching people through it, telling them `{1, :minutes}` and a sub-minute duration both mean "once that instant has passed".

## The decision

`fire_at` names the field holding the deadline instant, and takes no duration.

```elixir
timeout :dormant do
  fire_at :next_check_at
  transition_to :dormant_review
end
```

`fire_at` and `fire_after` are mutually exclusive, and `AshWorkflow.Verifiers.ValidateWorkflow` requires exactly one of them. `field` is rejected alongside `fire_at`, because `field` is the anchor `fire_after` measures from and a deadline instant has no anchor.

`fire_at` takes an atom naming an attribute or an expression calculation, checked by `AshWorkflow.Verifiers.ValidateTimeoutFields` exactly as `field` is. An inline expression, desugared at compile time into a generated calculation, would remove the need to declare that calculation by hand. It is not in this change.

## `Work.deadline` grows a second shape rather than a second key

`AshWorkflow.Scheduler.Work`'s `deadline` was `%{field: atom(), fire_after: duration()}`, and every registering scheduler reads it to compute the instant a record becomes eligible. A `fire_at` timeout has no duration to put there.

Two shapes were considered. A separate key, `%{field: ..., fire_at: ...}`, would make every reader match on which key is present. A `nil` `fire_after` instead means "the field holds the instant", and `AshWorkflow.Scheduler.due_at/2` resolves both to a `DateTime`. An implementation that arms timers reads the instant and never sees the shape, which is what `due_at/2` exists for.

The same choice runs through `AshWorkflow.Scheduler.Precise.Timeline.due_records/3`. It computes `bound = cutoff - fire_after` in Elixir so the comparison against the indexed column stays a bind parameter. For a `fire_at` deadline the bound is `cutoff` itself, so the query keeps that property with no arithmetic at all.

## The precision verifier skips a `fire_at` timeout

`AshWorkflow.Verifiers.ValidateTimeoutPrecision` compares `AshWorkflow.Duration.to_milliseconds(timeout.fire_after)` against `AshWorkflow.Scheduler.precision_floor_ms/1`, which is 60 seconds for `AshWorkflow.Scheduler.Oban` and 1 millisecond for `AshWorkflow.Scheduler.Precise`. It exists so the DSL cannot promise a deadline the scheduler will miss by more than the deadline itself.

A `fire_at` timeout makes no duration promise. It says "once this instant has passed", and the polling interval decides how soon after. There is no promised precision to compare against the floor, so the verifier skips it.

That is the same outcome the `{1, :seconds}` sentinel produced by a worse route: the sentinel handed the verifier a number that meant nothing, and the verifier checked it, applied the floor to it, and rejected it under `AshWorkflow.Scheduler.Oban` unless the author also wrote `self_scheduled?: true` or rounded up to `{1, :minutes}`. Skipping a `fire_at` timeout is correct by construction rather than by coincidence, so the coaching paragraph in that verifier's error message now points at `fire_at`.

## Indexes follow the field a timeout reads

`AshWorkflow.Info.recommended_indexes/1` returns a `(state, field)` composite per distinct timeout field, and `AshWorkflow.Transformers.AddIndexes` adds them on `AshPostgres.DataLayer`. A `fire_at` field is filtered on exactly as a `field` is, `state = $1 AND expires_at <= now()`, so it earns the same index. `AshWorkflow.Entities.Timeout.deadline_field/1` is the single place that answers "which datetime field does this timeout read", and the index generation, the trigger's `match`, the `pending_deadlines` calculation and the field verifier all ask it.

## Reading a calculation deadline

`AshWorkflow.Scheduler.due_at/2` reads the deadline field off the record with `Map.get/2`, which finds `%Ash.NotLoaded{}` for a calculation nobody loaded, and a `fire_at` pointing at an expression calculation walks into that. `due_at/2` returns `nil` for an unloaded calculation rather than raising, and `AshWorkflow.Scheduler.Precise.Timeline` loads a calculation deadline field with the records it sweeps and re-reads before firing, so it arms its timers from a value. A caller computing `due_at/2` from a record of its own still loads the calculation itself, which is [issue #70](https://github.com/team-alembic/ash_workflow/issues/70).
