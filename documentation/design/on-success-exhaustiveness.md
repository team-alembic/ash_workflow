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
other half: if no entry is unconditional, `on_error` must be declared. A step
whose conditions are semantically exhaustive (`attempts < 3` /
`attempts >= 3`, or a plain boolean and its negation) but not syntactically
so — no trailing bare `on_success` — still needs `on_error`, because the
verifier cannot evaluate arbitrary `Ash.Expr` conditions for logical
completeness. `AshWorkflowTest.OnSuccessThreeWayWorkflow`,
`OnSuccessSelfLoopWorkflow`, `OnSuccessBackwardLoopWorkflow` and
`OnSuccessCalculationWorkflow` all fell into this and gained an `on_error`
target as part of this change — a real breaking change, not just a new
error message, since workflows compiling today with routes like these will
need one added.

At runtime, `AshWorkflow.Changes.ConditionalOnSuccess` adds
`AshWorkflow.Errors.NoMatchingRoute` — naming the resource, the step and the
action — to the changeset on a no-match, which fails the action and runs
down `on_error` the same way any other failure does (see
`documentation/topics/error-handling.md`). A step the verifier somehow missed
still has no `on_error` to route to; `ConditionalOnSuccess` raises directly
in that case rather than returning a changeset error nobody declared a
destination for, the same defensive posture `AddActions` already takes for a
step naming an action that does not exist.

## Where the DSL goes

Two shapes were on the table.

**Add an `otherwise` entity**, so the fallback is spelled differently from a
conditional route:

```elixir
step :hr_decision do
  action :record_hr_screen

  on_success :background_check, when: expr(score >= 4)
  otherwise :rejected
  on_error :rejected
end
```

Every `on_success` entry would require `when`; the only way to declare an
unconditional target becomes `otherwise`.

**Keep the trailing-unconditional `on_success` form** and only change the
no-match behaviour, which is what shipped.

`otherwise` reads better exactly where the motivating example hurts: a
bare `on_success :rejected` still has the same shape as a conditional entry,
so a reader has to check for a `when` (or trust the ordering rule) to know it
is the fallback rather than one case among several. `otherwise` removes that
ambiguity outright — there's nothing to check, since only one entity spells
"unconditional".

Weighed against a wider break for a narrower gain. `on_success` appears 93
times across this repo's own test fixtures and docs, the overwhelming
majority a single unconditional entry (`on_success :done`) — the common case
for a workflow with no branching. Under `otherwise`, `on_success` would
always require `when`, so every one of those becomes `otherwise :done`
instead, on top of the `on_error`-exhaustiveness change already forcing
several fixtures to change. `validate_on_success_ordering` already rejects
an unconditional entry that is not both unique and trailing, so the
shadowing hazard `otherwise` would remove is already a compile-time error
today, not a silent bug — what `otherwise` buys is legibility, not
correctness. A new entity also means a new schema, a new verifier branch,
new cheat-sheet entries and new tests duplicating most of `on_success`'s own
coverage, for a step that is one line different from what it replaces.

The trailing-unconditional form stays. The readability complaint in the
motivating example is real, but it is a naming collision between `on_error`
and `on_success`'s fallback target (`:rejected` named by both), not a defect
in the form itself — renaming the fallback target, or reading `on_success`'s
declaration-order rule once, resolves it without a new entity. `otherwise`
is worth reconsidering if a future change also needs the DSL to distinguish
"the outcome" from "the fallback" for some other reason — a single
readability complaint on its own did not clear that bar.
