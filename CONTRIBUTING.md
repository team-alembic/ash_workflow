# Contributing to AshWorkflow

Thanks for your interest in AshWorkflow. Bug reports, questions and pull
requests are all welcome.

## Getting set up

AshWorkflow's test suite runs against both ETS and a real PostgreSQL database,
so you need Postgres available locally.

```bash
mix deps.get
mix test
```

`mix test` creates and migrates the test database for you. Connection details
come from `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER` and
`POSTGRES_PASSWORD`, defaulting to `postgres:postgres@localhost:5432`.

To drop and recreate the database from scratch:

```bash
mix test.reset
```

## Before opening a pull request

Run the same checks CI runs:

```bash
mix check
```

That covers compilation with warnings as errors, formatting, Credo in strict
mode, Dialyzer, the test suite, documentation, and a check that
`usage-rules.md` is in sync.

## How the extension is structured

AshWorkflow is a Spark DSL extension. Understanding the pipeline makes most
changes straightforward:

- `lib/ash_workflow.ex` — the DSL definition: sections, entities, schema
- `lib/ash_workflow/entities/` — the structs each DSL entity builds
- `lib/ash_workflow/transformers/` — where generation happens. These run in a
  defined order and inject `ash_state_machine`, `ash_oban`, action, policy,
  calculation and attribute DSL into the resource
- `lib/ash_workflow/verifiers/` — compile-time validation of a workflow
- `lib/ash_workflow/info.ex` — introspection API

Transformers must declare their ordering (`before?/1`, `after?/1`) relative to
the `ash_state_machine` and `ash_oban` transformers they feed. Getting this
wrong usually shows up as a confusing DSL error rather than a test failure.

## Expectations for changes

**Generation changes need tests at both levels.** A test asserting the
generated DSL is not enough on its own — `test/postgres/` exists because
`on_error` was generated correctly for months while never actually firing. If
your change affects what Oban runs, add a test that runs it.

**DSL changes are documentation changes.** A new or changed option needs to be
reflected in:

- `usage-rules.md` (and `usage-rules/`) — these are what LLM coding agents read
- the relevant guide under `documentation/`
- `examples/` if the change makes an example wrong. Examples are compiled by
  CI, so a breaking DSL change will fail the build until they are updated
- `.formatter.exs` `locals_without_parens`, for a new DSL keyword
- `CHANGELOG.md`, under `## [Unreleased]`

The DSL reference at `documentation/dsls/DSL-AshWorkflow.md` is generated — run
`mix spark.cheat_sheets` rather than editing it.

**Commit messages** follow [Conventional Commits](https://www.conventionalcommits.org/).
Use `feat!:` or a `BREAKING CHANGE:` footer for anything that changes the DSL
or generated action names.

## Versioning

AshWorkflow is pre-1.0. Breaking changes go out in a minor version bump, and
are called out explicitly in the changelog with migration instructions.

## Code of Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md). By
participating you are expected to uphold it.
