# Temporal probes

Four runnable scripts behind the claims in `../temporal-exploration.md` §13–§16,
and behind Act V of the talk. Each one prints its own verdict, so a claim that
stops being true says so rather than going quietly stale.

All four run on `Ash.DataLayer.Ets`, so none of them needs PostgreSQL 19. They do
need the `temporal` branch pins in the root `mix.exs`, which is the top commit of
this branch.

```sh
MIX_ENV=test mix run .claude/plans/temporal-probes/anchor.exs
MIX_ENV=test mix run .claude/plans/temporal-probes/walk.exs
MIX_ENV=test mix run .claude/plans/temporal-probes/manual_read.exs
MIX_ENV=test mix run .claude/plans/temporal-probes/no_all_history.exs
```

A cold `mix deps.compile ash` fails on the temporal branch. Build `ash` at `main`
first, then check out the temporal sha and recompile — see §9.

| script | claim | result when last run (2026-09-11) |
|---|---|---|
| `anchor.exs` | `lower(valid_at)` tracks the last write, not state entry | an `add_note` update moved the bound while `state` held at `:review` |
| `walk.exs` | the version chain is walkable without guessing instants | 4 versions in 5 queries, following each version's `upper` |
| `manual_read.exs` | a manual read returns every version at once | ordinary read 1 row, manual read 4 rows in one query |
| `no_all_history.exs` | omitting `as_of` does **not** return history | 1 row, same as `as_of: :now` |

`anchor.exs` is the one that matters most. It refutes the original plan for
dropping `state_entered_at` on temporal resources, and the Act V slide that used
to be built on it.
