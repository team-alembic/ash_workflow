# Making on_success exhaustive

## The question

A step reads:

```elixir
step :hr_decision do
  action :record_hr_screen

  on_success :background_check, when: expr(score >= 4)
  on_success :rejected
  on_error :rejected
end
```

The trailing unconditional `on_success :rejected` is the fallback: the
route that runs when the conditional one above it does not match. It sits
right next to `on_error :rejected`, which runs for a different reason — the
action itself failed. Both name the same target here, which is exactly what
makes the step hard to read: a glance cannot tell which line is "no route
matched" and which is "the action raised".

Runtime already treats a no-match as a failure. `AshWorkflow.Changes.ConditionalOnSuccess`
added a changeset error when no route matched before this change; the record
never moved, and the action returned `{:error, ...}`. What was missing:

- The error was a bare string, not a typed one a caller could match on.
- Nothing at compile time asked whether a step *could* reach that failure
  with no way to recover. A step with two conditional `on_success` entries
  and no `on_error` compiled, and its no-match case only ever printed the
  string, was retried on the scheduler's ordinary cadence, and (per
  `documentation/topics/error-handling.md`) stayed in the step forever if
  the condition kept failing to match.

Two independent things to fix: give the DSL an exhaustiveness rule the
verifier can enforce, and decide whether the DSL itself needs a new entity to
make the fallback route legible.

## The exhaustiveness rule

`AshWorkflow.Verifiers.ValidateWorkflow` already requires an unconditional
`on_success` to be unique and trailing (`validate_on_success_ordering`) — the
DSL can already prove, from the declaration alone, when a step's routes are
guaranteed to cover every case. `validate_on_success_exhaustive` adds the
other half: if no entry is unconditional, the step must declare some other way
out.

Two count as a way out, because both move the record:

- `on_error`. The scheduler runs it once the final attempt has failed.
- A timeout with `transition_to`. The record waits in the step until the
  deadline passes, then moves. A timeout that only names an `action` does not
  count: it never changes state, so it leaves the record where it was.

With neither, the record stays in the step and the action is retried on every
scheduler cycle forever, which is the dead end this rule exists to reject.

A step whose conditions are semantically exhaustive (`attempts < 3` /
`attempts >= 3`, or a plain boolean and its negation) but not syntactically
so — no trailing bare `on_success` — still needs one, because the verifier
cannot evaluate arbitrary `Ash.Expr` conditions for logical completeness.
`AshWorkflowTest.OnSuccessThreeWayWorkflow`, `OnSuccessSelfLoopWorkflow`,
`OnSuccessBackwardLoopWorkflow` and `OnSuccessCalculationWorkflow` all fell
into this and gained an `on_error` target as part of this change — a real
breaking change, not just a new error message, since workflows compiling today
with routes like these will need one added. Two of the four were not
exhaustive even by value: `valid == true` / `valid == false` and `is_strong` /
`not is_strong` both leave a `nil` unmatched, since a comparison against `nil`
evaluates to `nil` rather than `false`.

At runtime, `AshWorkflow.Changes.ConditionalOnSuccess` adds
`AshWorkflow.Errors.NoMatchingRoute` — naming the resource, the step and the
action — to the changeset on a no-match, which fails the action and runs
down `on_error` the same way any other failure does (see
`documentation/topics/error-handling.md`). It never raises: a raise would
break the `{:error, _}` contract a direct `Ash.update/2` call expects, and on
the scheduler's path a raise and a changeset error produce the same failed
job.

## Where the DSL goes

The complaint that opened this is about reading, not behaviour:

```elixir
step :hr_decision do
  action :record_hr_screen

  on_success :background_check, when: expr(score >= 4)
  on_success :rejected
  on_error :rejected
end
```

A bare `on_success :rejected` has the same shape as a conditional entry, so a
reader has to notice the absent `when` — or know the ordering rule — to see it
is the fallback rather than one case among several. An `otherwise :rejected`
would say it outright.

Three shapes were considered.

Replacing the bare form with a required `otherwise` makes every `on_success`
entry take a `when`, leaving `otherwise` as the only unconditional spelling.
This is the widest break of the three: 64 unconditional `on_success`
declarations across this repo's fixtures and docs alone, almost all of them
`on_success :done` on a step with no branching at all, would each become
`otherwise :done`.

Adding `otherwise` as optional sugar costs nothing already written. It builds
the same `AshWorkflow.Entities.Route` with `when: nil`, appended last;
`validate_on_success_ordering` is unchanged, and one new verifier clause
rejects a step declaring both `otherwise` and a bare trailing `on_success`.
The cost is an entity, a transformer branch, a verifier clause, cheat-sheet
entries and tests — for a second spelling of a route the DSL can already
express.

Keeping the bare trailing form and changing only the no-match behaviour is
what shipped.

The last one shipped because this PR's job was the routing contract, and that
is settled by the verifier rule and `NoMatchingRoute` regardless of how the
fallback is spelled. The two are genuinely independent: adding `otherwise`
later changes no behaviour this PR defines, and needs no second breaking
change, precisely because the sugar form breaks nothing.

Stated plainly, so the next reader is not misled: this PR does not resolve the
readability complaint. It defers it. The bare `on_success :rejected` next to
`on_error :rejected` reads exactly as ambiguously after this change as before,
and `:rejected` being named by both is the ordinary case — a low score and a
failed screen both rejecting is the same business outcome by two routes, not a
naming mistake to rename away. The optional-sugar form is the version worth
picking up if the complaint recurs; the argument against it is cost against a
readability gain, not a claim that it would break anything.
