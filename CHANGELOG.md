# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
