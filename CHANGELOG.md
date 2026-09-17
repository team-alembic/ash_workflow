# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.0] - 2026-09-17

### Added

- **A pluggable scheduler.** `AshWorkflow.Scheduler` is the behaviour a module implements to decide when a workflow's automatic steps and timeouts run. Choose one on the `workflow` block with `scheduler`, or once for an application with `config :ash_workflow, scheduler: ...`. `AshWorkflow.Scheduler.Oban` is the default and generates the same AshOban triggers as before, with the same trigger, worker and scheduler module names, so nothing already enqueued is orphaned.
- `AshWorkflow.Scheduler.Work` describes one unit of scheduled work in AshWorkflow's own terms. It carries `match`, an expression selecting records eligible now, and `deadline`, the rule for computing the exact instant — the same fact in the two shapes that opposite scheduling strategies need. A scheduler that polls reads one; a scheduler that arms timers reads the other.
- `AshWorkflow.Scheduler.execute/3` runs a unit of work and routes failure to the step's `on_error`. It belongs to AshWorkflow rather than to each implementation, so changing the scheduler changes when work happens and never what it does.
- `AshWorkflow.Info.scheduler/1`.
- `AshWorkflow.Info.transition/2`, returning the merged view of a transition name: every step it leaves, one route per declared target with the `when` expression that selects it, the union of the accepted inputs, and the generated action name. A name declared on more than one step becomes a single action, and reading what that action accepts and where it can go previously meant combining the workflow entities with the generated Ash action by hand.
- **`state_attribute` on the `workflow` section.** Names the attribute the current step is stored in, and is passed down to `ash_state_machine`. It defaults to `:state`, so nothing changes for workflows that do not set it. A resource that already has a lifecycle column of its own — `status`, say — can now use AshWorkflow without renaming that column. Everything generated follows the name: the state machine, the transition and timeout actions, the `match` expression on every `AshWorkflow.Scheduler.Work`, the `current_step`, `available_actions` and `pending_deadlines` calculations, and `AshWorkflow.Info.recommended_indexes/1`. `AshWorkflow.Info.state_attribute/1` reports it. The `state_entered_at` attribute keeps its name.
- **A `retry` block on a step or a timeout.** Declares `max_attempts` and `backoff` for its generated work, so a failing step or timeout action can run again before `on_error` moves it to its error state. `max_attempts` defaults to `1`, so nothing changes for a step or timeout that does not declare one. `AshWorkflow.Scheduler.Oban` turns the block into the generated trigger's own `max_attempts` and `backoff`. `AshWorkflow.Scheduler.Precise` re-arms its timer for the backoff delay instead, under the same key the original deadline used. `AshWorkflow.Verifiers.ValidateRetry` rejects the block on a manual step, a wait state, or a terminal step, since none of them has a generated trigger for it to apply to.
- **`self_scheduled?` on a timeout.** Declares that something other than cron drives this trigger, at whatever resolution the deadline needs, which permits a deadline shorter than a cron expression can ask for. It changes nothing about what is generated — the scheduler module and its cron still exist, so `AshOban.schedule/2` and `AshOban.schedule_and_run_triggers/1` keep working. `demos/ats` is the worked example: a GenServer ticks every second and invokes the trigger, which is what makes its 30-second deadline honourable.
- Compile-time rejection of a transition name shared across steps that declare different policies. Because such steps merge into one action and Ash requires every applicable policy to pass, the differing policies blocked each other and nobody could call the action — a silent runtime lockout, now a build error with guidance.
- **Indexes for the generated triggers.** Resources using `AshPostgres.DataLayer` now get a `(state, <timeout field>)` composite index per distinct timeout field, or `(state)` alone for workflows with no timeouts. Every trigger filters on `state`, and `ago/2` compiles to a bind parameter rather than a per-row function call, so a timeout's query reaches Postgres as `state = $1 AND state_entered_at <= $2` — indexable all along, but unindexed by default, which made every poll a sequential scan. Indexes are created `concurrently`, so adding them to an existing table does not lock it. An existing `custom_indexes` entry on the same fields takes precedence.
- `generate_indexes?` on the `workflow` block, to turn that off.
- `AshWorkflow.Info.recommended_indexes/1`, returning the same list as data, for resources on other data layers and for tooling.
- **`pending_deadlines` calculation.** Lists the timeouts ahead of a record in its current step, soonest first, each with `due_at`, `kind` and `target`. Derived on read from the DSL and the record's own timestamps, so there is no new table and nothing that can drift out of sync — a forward-looking companion to the transition log's history. A `due_at` in the past means "was due", not "will fire": a non-repeating action timeout does not change state, so its deadline stays derivable after it fires.
- **Conditional `on_success` routing.** `on_success` is now a repeatable entity instead of a scalar option, so an automatic step can fan out to different states based on what its action computed: `on_success :interview, when: expr(screen_score >= 5)`. It reuses the same `AshWorkflow.Entities.Route` entity conditional transitions already use, and the inline shorthand (`step :x, action: :y, on_success: :z, on_error: :w`) still works for the common unconditional case. `on_success` conditions evaluate after the step's own action has run, since the point is to branch on what the action produced — the same way a manual transition's `route` conditions do. Entries are evaluated in declaration order, first match wins; at most one unconditional `on_success` is allowed per step, and it must come last, as the fallback.
- **Undo.** An `undo` block on the `workflow` section, plus `undoable?: true` on individual transitions, generates an `undo` action that rewinds a record to the state before its most recent state change. Opt-in twice over: nothing is undoable unless declared so, because undo restores *state* only — it does not roll back accepted attributes or compensate side effects. Optional `within` (time limit) and `same_actor?` (only the actor who transitioned) constraints, and a `policy` of its own, since no step's policy can govern an action that spans two states.
- **Undo appends, never erases.** An undo writes a new transition log row with `triggered_by: :undo` and `undoes_id` pointing at the row it reverses. The log stays append-only, and both readings of history remain derivable from the same rows: `history/2` and `state_at/3` answer literally by default, or from the corrected account with `effective: true`. Undoing an undo is a redo and needs no special handling. See `documentation/design/workflow-undo.md` for why this was chosen over an `undone` flag on the reversed row.
- `undoable?/2` and `undo_target/2` on resources with undo enabled, answering whether a record can be rewound and where it would land without writing. Distinct from Ash's generated `can_undo?/2`, which asks whether the actor is authorized to call the action.
- `AshWorkflow.Info.undoable_edges/1` and `undoable_edge?/3`, and `AshWorkflow.Errors.UndoNotPermitted` with a `reason` field so callers can branch without matching on message text.
- Compile-time rejection of incoherent undo configuration: `undo` without a `transition_log`, a log without the self-referencing `undoes` relationship, an `undo` block with nothing marked undoable, `undoable?: true` with no `undo` block, and `same_actor?` without `belongs_to_actor`.
- **Wait states.** A step that declares no action and no transitions, whose only exit is a timeout with `transition_to`, is now a valid step. Previously such a step was misclassified as automatic and failed to compile with `references action :, but no such action is defined`, which made "sit here until a deadline passes" inexpressible even though the generated timeout triggers already supported it. Combined with a timeout `field`, this is how you give each record its own delay without blocking a process to wait for it.
- `AshWorkflow.Entities.Step.wait_state?/1`, alongside the existing `manual?/1`.
- Compile-time rejection of a wait state whose timeouts all lack `transition_to` (records could never leave), or which declares `on_success`/`on_error` (with no action, neither could fire).
- `check_interval` on the `workflow` block, setting the Oban cron for every generated trigger on the resource — automatic steps included, which previously had no way to change their polling interval at all. Individual timeouts still override it.
- Documentation of what polling costs: one scheduler per trigger, each querying on every tick regardless of whether any record is waiting, so the cost scales with the size of the workflow rather than the number of records.

### Changed

- **Breaking:** The `timeout` entity's `after` option is renamed to `fire_after`, with no alias. `after` is a reserved block clause in Elixir, so `timeout :x do after {3, :days} ... end` never parsed — it swallowed every following line into an `after:` clause — and a timeout that also wanted a `retry` block had no inline spelling left to reach for. `fire_after` is not reserved, so both the inline form and the block form work, and a timeout can now combine a duration with a `retry` block without contorting the call into `do: (retry do ... end)`. A workflow still declaring `after: {3, :days}` fails to compile with `unknown options [:after], valid options are: [..., :fire_after, ...]`; rename the option to fix it. The `deadline` map `AshWorkflow.Scheduler.Work` builds for a timeout renames its `after` key to `fire_after` the same way.
- **Breaking: `AshWorkflow.Info.workflow_graph/1` returns everything the entities hold.** Each step's entry keeps its `:terminal` and `:manual` flags and gains `:name`, `:action`, `:policy`, `:retry`, `:initial` and `:wait_state`. `:transitions` is now a list of maps rather than of target names, one per reachable target, carrying `:name`, `:to`, `:condition`, `:undoable?` and `:accept`. A conditional transition contributes one entry per route, each with that route's `when` expression as `:condition`. `:timeouts` is a list of maps rather than of `{name, target}` tuples, carrying `:name`, `:to`, `:fire_after`, `:field`, `:action`, `:repeat` and `:retry`, so a timeout that runs an action is distinguishable from one that moves the workflow. `:on_success` is a list of `%{to:, condition:}` routes in declaration order, replacing both the old scalar `:on_success` and `:on_success_targets`. A caller drawing the workflow can now label every edge, show which branch is conditional and mark the entry point without calling anything else.

- **Breaking:** Resources must add the `AshOban` extension themselves:

      use Ash.Resource,
        domain: MyApp.Domain,
        extensions: [AshWorkflow, AshOban]

  AshWorkflow no longer adds it. `add_extensions` is static in `use Spark.Dsl.Extension`, so it cannot depend on which scheduler a workflow selects — and a workflow whose deadlines are run by something other than Oban should not carry the ash_oban DSL. `AshWorkflow.Scheduler.Oban` checks for the extension and fails at compile time with the fix in the message. `AshStateMachine` is still added for you.

- **Breaking:** A timeout whose `fire_after` is shorter than one minute is now a compile error unless it sets `self_scheduled?: true`. Timeouts fire when an Oban cron scheduler next notices the deadline has passed, and cron cannot poll below one minute — `Oban.Cron` zeroes the seconds field and only wakes on minute boundaries. So `fire_after: {30, :seconds}` compiled happily and then fired up to 60 seconds late, an error larger than the deadline itself. The DSL accepted `:seconds` durations and the docs advertised them, which made this a documented promise the scheduler could not keep.

  Sub-minute durations paired with a custom `field` were an idiom for "as soon as that instant has passed", since `fire_after` must be positive. Spell that `{1, :minutes}` — under any polling interval it means the same thing.

- **Breaking:** Timeout-generated names are now scoped by step. The hidden action is `__timeout_<step>_<name>` (was `__timeout_<name>`), its Oban trigger is `__timeout_trigger_<step>_<name>`, and worker/scheduler modules gain a step namespace. This means two steps can each declare a timeout with the same name — previously that failed to compile with an ash_oban "defined more than once" error. Update any code referring to a generated timeout action by name.
- **Breaking:** The minimum supported Elixir is now 1.17, raised from 1.15. The ash release carrying the security fixes below uses `Duration`, which does not exist before 1.17, and the newest ash that still compiles on 1.15 (3.30.1) remains affected by the HIGH advisory — so supporting 1.15/1.16 and shipping a patched ash were mutually exclusive.
- `AshWorkflow.Transformers.AddObanTriggers` is replaced by `AshWorkflow.Transformers.AddScheduler`, which builds the `Work` list and delegates to the selected scheduler.

- **`terminal: true` is derived.** A step that declares no action, no transitions, no timeouts, no `on_success` and no `on_error` has no way out, so `AshWorkflow.Entities.Step.terminal?/1` reports it as terminal whether or not the option is set. `step :approved` is now enough. The option stays as an assertion: `AshWorkflow.Verifiers.ValidateWorkflow` still rejects a step that sets it and then declares something outgoing, and everything that reads the flag — the scheduler's work list, the generated policies, the state machine, `AshWorkflow.Info.workflow_graph/1` — now reads the predicate.

  A step that becomes terminal by accident is caught by the reachability check rather than by a missing-action error: an end state nothing transitions to is unreachable. The error for a stranded step therefore changes. `step :stranded` in an otherwise working workflow now reports "not reachable from the first step", and a workflow of nothing but terminal steps reports "must have at least one non-terminal step".

- Triggers now stream with `:keyset` rather than `:full_read`. ash_oban suggests `:full_read` when a `where` clause changes between batches, which ours do, but keyset orders by primary key: unlike `:offset`, a row leaving the filter mid-stream cannot shift another row past the cursor. A record becoming eligible at a key the stream has already passed waits for the next poll, bounded by `check_interval`. In exchange, a backlog after downtime is no longer read into memory in one unpaginated read.
- `mix ash_workflow.gen.transition_log` now scaffolds a self-referencing `belongs_to :undoes` relationship and accepts `:undoes_id`. Logs generated before this need regenerating (or the relationship adding by hand) before undo can be enabled on their workflow.
- A timeout's `check_interval` now defaults to the workflow-level setting instead of hardcoding `"* * * * *"`. Behaviour is unchanged unless a workflow-level `check_interval` is declared.

### Fixed

- **A non-repeating action timeout now writes a transition log row.** `AshWorkflow.Transformers.AddActions` injected `AshWorkflow.Changes.RecordEvent` only onto actions named by a timeout with `repeat: true`, so a one-shot reminder fired and left no trace in the log. Every timeout that names an action now gets the change, and the row has `from_state == to_state` with `triggered_by: :timeout`, the same shape a repeating timeout's row already had. Two timeouts naming the same action share one row per firing. Only a repeating timeout's action resets `state_entered_at`, through the new `:touch_state_entered_at` option on `AshWorkflow.Changes.RecordEvent`: the reset is how a repeat re-arms its trigger, and a one-shot timeout doing it would push every other deadline on the step back.
- **A policy with no authorizer to enforce it is a compile error.** `AshWorkflow.Transformers.AddPolicies` generates nothing when `Ash.Policy.Authorizer` is absent from the resource, so a `policy` on a step or on the `undo` block was accepted and then silently unenforced: every caller was authorized, including the ones the policy named. `AshWorkflow.Verifiers.ValidateStepPolicies` now names each step that declared one and says how to add the authorizer.
- A timeout naming an action the resource does not define is rejected by `AshWorkflow.Verifiers.ValidateWorkflow`. Under the default scheduler AshOban's own verifier caught it on the trigger it generated, but a workflow scheduled by `AshWorkflow.Scheduler.Precise` generates no trigger, so the name went unchecked until the deadline passed.
- A timeout `field` referencing a module calculation is now rejected at compile time. Only expression calculations inline into a data-layer filter, so a module calculation passed the verifier and then raised when the scheduler built its query. Use an expression calculation or a plain attribute.

- A manual transition's `route` conditions now see the input the same call accepted. `AshWorkflow.Changes.ConditionalTransition` evaluated them against `changeset.data`, so `route :approved, when: expr(decision == :approve)` on a transition that accepts `:decision` could only match a value already persisted, and "submit the outcome, then route on the outcome" needed a separate transition name per outcome or a custom change. Routes now read the record as it was loaded with the transition's `accept` list applied on top.

  Only the accepted attributes are applied. An attribute written by one of the action's own changes stays invisible to the routes, so a route can still ask what the record looked like when the call arrived — which is what a two-signature sign-off needs, where one action records the current approver and the routes ask whether anyone approved before. `AshWorkflow.Changes.ConditionalOnSuccess` continues to apply every pending attribute, since an automatic step has no caller input to distinguish from what its action computed.

- `from_state` is no longer lost on atomic transitions. An atomic update acts on a query rather than a loaded record, so the changeset has no `data` to read the pre-update state from — and that is the path AshOban drives every automatic step and timeout through, meaning most rows on a busy workflow logged `from_state: nil` and were indistinguishable from the `:initial` row a create writes. The state is now taken from the last logged row when the changeset cannot supply it.
- `mix igniter.install ash_workflow` works. `igniter` was declared as an unqualified dependency, so it diverged from the `only: [:dev, :test]` that consuming applications use — including the one `igniter.install` sets up itself — and the install aborted with "Dependencies have diverged". It is now `optional: true`, matching `ash`; the mix tasks were already guarded on `Code.ensure_loaded?(Igniter)`.
- A resource with the extension but no steps yet reports "Workflow must have at least one non-terminal step." rather than an internal `expected a map, got: nil` from `AddStateMachine` — the state every resource is in between `mix ash.extend` and writing its first step. The verifier always had the right message, but transformers run first.
- The generated primary read action no longer collides with a read action the resource already defines. A resource whose `:read` was not primary — `defaults [:read]` produces exactly that — got a second action of the same name and failed to compile with "Multiple actions (2) with the name `read` defined". The transformer now runs after `Ash.Resource.Transformers.SetPrimaryActions`, which is what expands `defaults` and marks primaries — asking before it ran meant seeing no read action at all on some Elixir versions and generating a duplicate. As a second guard, the generated action is named `:__workflow_read` when `:read` is already taken.
- A step declaring neither an action, a transition, nor a timeout now reports what it needs, rather than the misleading `Automatic step :x references action :, but no such action is defined on the resource.`
- The generated `__on_error_<step>` action is now covered by the generated policies and the AshOban bypass. On a resource with an authorizer, AshOban's invocation of it was forbidden, so a failing automatic step silently stayed put instead of routing to its error state.
- Corrected the conditional route example in `AshWorkflow.Entities.Transition` docs, which used `to :target, when: ...` rather than the actual `route :target, when: ...`.
- `documentation/topics/error-handling.md` described failure behaviour the library has not had since 0.5.0. It said the `on_error` transition never happens automatically, that a failing job retries, and that the record stays in the failing step once retries are exhausted. `AshWorkflow.Transformers.AddActions` generates `__on_error_<step>` and `AshWorkflow.Transformers.AddScheduler` wires it to the trigger, so the record moves to the error state on the first failure and gets an `:error_path` transition log row. The guide now documents that, and what a step with no `on_error` does instead.
- `documentation/topics/timeouts-and-deadlines.md` recommended `"* * * * * *"` for sub-minute precision, which `AshWorkflow.Verifiers.ValidateTimeoutPrecision` rejects. It now points at `AshWorkflow.Scheduler.Precise` and `self_scheduled?`, which is what the rest of the guide already taught.
- The same guide said a non-repeating timeout on a custom field keeps firing on every poll cycle. Its trigger keeps matching, but `trigger_once?` stops the action running twice for the same record.
- The getting-started tutorial asked for `ash_state_machine` and `ash_oban` as prerequisites the reader adds and configures. It now leads with `mix igniter.install ash_workflow` and keeps manual setup as the fallback. One dependency rule holds across the tutorial and the README: declare `ash_workflow` only, add `AshWorkflow` and `AshOban` to the resource, never `AshStateMachine`.
- The tutorial and the README now say that AshWorkflow generates no create action, and show what `initial: true` changes, since the initial step is otherwise the first non-terminal step by declaration order.
- README links into `demos/` are absolute, so they resolve on HexDocs. `mix docs` emitted six unresolved-reference warnings, because the demos are not part of the published package.

### Security

- Updated the locked `ash` from 3.27.7 to 3.32.1, which carried four advisories. The most serious, EEF-CVE-2026-67579 (HIGH), is filter expression injection via a forged keyset pagination cursor — relevant here because the read action this extension generates for ash_oban's triggers uses keyset pagination. The dependency constraint (`~> 3.0`) was already permissive; only the lockfile held the old version.
- Updated the locked `ash` to 3.33.5, which fixes EEF-CVE-2026-86338 (MEDIUM): field policies do not filter-nil forbidden calculations and aggregates, so a forbidden value can be inferred from whether a row is returned. Introduced in 2.11.0-rc.0 and fixed in 3.33.4. The `~> 3.0` constraint already allowed the fix; only the lockfile held the affected version.

## [0.5.0] - 2026-08-21

### Added

- `AshWorkflow.Info` introspection helpers: `terminal?/2`, `in_terminal_state?/1`, `initial_step/1`
- Compile-time validation that a timeout `field` resolves to a datetime type, rather than only checking that the attribute exists
- `documentation/topics/error-handling.md` and `documentation/topics/bpmn-comparison.md` guides
- `mix ash_workflow.install` igniter installer, which configures Oban, the cron plugin, the workflow queue and the formatter import
- Postgres and Oban integration test suite, covering trigger scheduling, execution, error routing and timeout firing against a real database

### Changed

- Minimum supported `ash` is now exercised against 3.27; the test suite and CI run against Elixir 1.15 through 1.19
- **Breaking:** Removed the `manual true` option from `step`. A step is now implicitly manual when it declares one or more `transition` entries — the flag was always redundant with the presence of transitions. Update existing workflows by deleting the `manual true` line from each manual step.

### Fixed

- **`on_error` now actually fires.** An automatic step's `on_error` target was declared as a state machine transition on the step's own action, but nothing ever invoked it — a failing step stayed in place and was retried instead of moving to the error state. AshWorkflow now generates an `__on_error_<step>` action and wires it to the AshOban trigger's `on_error`. If you were matching on state machine transitions for the error path, the transition is now declared on `__on_error_<step>` rather than on the step's action.
- Expression evaluation errors in conditional transitions are now reported with the failing route and underlying error, instead of being silently treated as "no match"
- Entity structs now define a `__spark_metadata__` field, fixing compatibility with newer Spark versions

### Documentation

- Removed references to the removed `manual true` option and the generated `:start` action from the README, usage rules and examples
- Documented the timeout `field` option in the usage rules, which had been undocumented since 0.3.0
- Added `LICENSE` (MIT), `CONTRIBUTING.md` and a code of conduct

## [0.4.0] - 2026-03-26

### Changed

- Workflow initialization now happens through user-defined create actions instead of a generated `:start` action
- `state_entered_at` is now non-null and defaults on create, so workflows enter their initial step implicitly when the record is created
- Documentation and examples now use explicit create actions, including an AshPhoenix form example for workflow initialization

## [0.3.0] - 2026-03-25

### Added

- `field` option on timeouts — specify which datetime attribute to measure `after` against (default: `:state_entered_at`), enabling data-driven deadlines like `field: :last_session_date`
- Compile-time validation that timeout `field` references an existing attribute or calculation
- Compile-time validation rejecting `repeat: true` with custom `field` (see `Entities.Timeout` for rationale)

## [0.2.0] - 2026-03-24

### Added

- `AshWorkflow.Info` introspection module with `steps/1`, `step/2`, and `available_actions/2`
- `:available_actions` calculation — returns user-facing transition names for the current step, with optional actor-aware policy filtering
- `:steps` calculation — returns all workflow step names
- `:current_step` calculation — returns the record's current step name
- `accept` option on transitions — generated actions accept specified attributes as input
- `initial true` flag on steps — explicit control over the initial state with verifier enforcement
- `repeat: true` on action timeouts — re-fires at the timeout interval by resetting `state_entered_at`
- `queue` option on workflow section — configurable Oban queue for all generated triggers (default: `:workflow`)

### Fixed

- Non-repeating action timeouts now use `trigger_once?` to prevent re-firing on every scheduler cycle
- ETS table race condition in async tests

## [0.1.0] - 2026-03-20

### Added

- Initial release
- Declarative workflow DSL with steps, transitions, and timeouts
- Automatic state machine generation via ash_state_machine
- Oban trigger generation for automatic steps and timeouts
- Manual step transitions with code interface generation
- Step-level authorization policies
- Conditional transitions with route guards
- Shared transition names across steps
