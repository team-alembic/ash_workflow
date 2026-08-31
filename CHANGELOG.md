# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Wait states.** A step that declares no action and no transitions, whose only exit is a timeout with `transition_to`, is now a valid step. Previously such a step was misclassified as automatic and failed to compile with `references action :, but no such action is defined`, which made "sit here until a deadline passes" inexpressible even though the timeout machinery supported it. Combined with a timeout `field`, this is how you give each record its own delay without blocking a process to wait for it.
- `AshWorkflow.Entities.Step.wait_state?/1`, alongside the existing `manual?/1`.
- Compile-time rejection of a wait state whose timeouts all lack `transition_to` (records could never leave), or which declares `on_success`/`on_error` (with no action, neither could fire).
- `check_interval` on the `workflow` block, setting the Oban cron for every generated trigger on the resource — automatic steps included, which previously had no way to change their polling interval at all. Individual timeouts still override it.
- Documentation of what polling costs: one scheduler per trigger, each querying on every tick regardless of whether any record is waiting, so the cost scales with the size of the workflow rather than the number of records.

### Changed

- **Breaking:** Timeout-generated names are now scoped by step. The hidden action is `__timeout_<step>_<name>` (was `__timeout_<name>`), its Oban trigger is `__timeout_trigger_<step>_<name>`, and worker/scheduler modules gain a step namespace. This means two steps can each declare a timeout with the same name — previously that failed to compile with an ash_oban "defined more than once" error. Update any code referring to a generated timeout action by name.

### Added

- Compile-time rejection of a transition name shared across steps that declare different policies. Because such steps merge into one action and Ash requires every applicable policy to pass, the differing policies blocked each other and nobody could call the action — a silent runtime lockout, now a build error with guidance.

### Changed

- **Breaking:** The minimum supported Elixir is now 1.17, raised from 1.15. The ash release carrying the security fixes below uses `Duration`, which does not exist before 1.17, and the newest ash that still compiles on 1.15 (3.30.1) remains affected by the HIGH advisory — so supporting 1.15/1.16 and shipping a patched ash were mutually exclusive.

### Security

- Updated the locked `ash` from 3.27.7 to 3.32.1, which carried four advisories. The most serious, EEF-CVE-2026-67579 (HIGH), is filter expression injection via a forged keyset pagination cursor — relevant here because the read action this extension generates for ash_oban's triggers uses keyset pagination. The dependency constraint (`~> 3.0`) was already permissive; only the lockfile held the old version.

### Fixed

- `from_state` is no longer lost on atomic transitions. An atomic update acts on a query rather than a loaded record, so the changeset has no `data` to read the pre-update state from — and that is the path AshOban drives every automatic step and timeout through, meaning most rows on a busy workflow logged `from_state: nil` and were indistinguishable from the `:initial` row a create writes. The state is now taken from the last logged row when the changeset cannot supply it.
- `mix igniter.install ash_workflow` works. `igniter` was declared as an unqualified dependency, so it diverged from the `only: [:dev, :test]` that consuming applications use — including the one `igniter.install` sets up itself — and the install aborted with "Dependencies have diverged". It is now `optional: true`, matching `ash`; the mix tasks were already guarded on `Code.ensure_loaded?(Igniter)`.
- A resource with the extension but no steps yet reports "Workflow must have at least one non-terminal step." rather than an internal `expected a map, got: nil` from `AddStateMachine` — the state every resource is in between `mix ash.extend` and writing its first step. The verifier always had the right message, but transformers run first.
- The generated primary read action no longer collides with a read action the resource already defines. A resource whose `:read` was not primary — `defaults [:read]` produces exactly that — got a second action of the same name and failed to compile with "Multiple actions (2) with the name `read` defined". The transformer now runs after `Ash.Resource.Transformers.SetPrimaryActions`, which is what expands `defaults` and marks primaries — asking before it ran meant seeing no read action at all on some Elixir versions and generating a duplicate. As a second guard, the generated action is named `:__workflow_read` when `:read` is already taken.
- A step declaring neither an action, a transition, nor a timeout now reports what it needs, rather than the misleading `Automatic step :x references action :, but no such action is defined on the resource.`
- The generated `__on_error_<step>` action is now covered by the generated policies and the AshOban bypass. On a resource with an authorizer, AshOban's invocation of it was forbidden, so a failing automatic step silently stayed put instead of routing to its error state.
- Corrected the conditional route example in `AshWorkflow.Entities.Transition` docs, which used `to :target, when: ...` rather than the actual `route :target, when: ...`.

### Changed

- A timeout's `check_interval` now defaults to the workflow-level setting instead of hardcoding `"* * * * *"`. Behaviour is unchanged unless a workflow-level `check_interval` is declared.

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
- Expression evaluation errors in conditional transitions are now surfaced with the failing route and underlying error, instead of being silently treated as "no match"
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
