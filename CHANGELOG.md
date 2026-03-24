# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `initial true` flag on steps — explicit control over the initial state with verifier enforcement
- `repeat: true` on action timeouts — re-fires at the timeout interval by resetting `state_entered_at`
- `queue` option on workflow section — configurable Oban queue for all generated triggers (default: `:workflow`)

### Fixed

- Non-repeating action timeouts now use `trigger_once?` to prevent re-firing on every scheduler cycle

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
