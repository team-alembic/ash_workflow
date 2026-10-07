# When Time Meets State — slides

The AshConf 2026 talk, built as a Marp deck in `2026-ashconf-when-time-meets-state/`. The deck follows OnlySands, a fictional company, through hiring a candidate. Slide content and order are in `deck.md`, and the `onlysands` theme is in `onlysands.css`.

## Building

The `justfile` runs Marp CLI through `npx`, so nothing needs installing beyond Node and `just`. Run `just` in this directory to list the recipes.

| Recipe | Does |
|---|---|
| `just dev` | watches the deck and opens Marp's preview window |
| `just serve [PORT]` | serves the deck at `http://localhost:8080/deck.md`, re-rendered on every reload |
| `just serve-wsl [PORT]` | `serve` with file-system polling, for WSL2 and Docker |
| `just preview` | opens the preview window once, without watching |
| `just html` | writes `2026-ashconf-when-time-meets-state/index.html` |
| `just pdf` | writes `2026-ashconf-when-time-meets-state/when-time-meets-state.pdf` |
| `just pptx` | writes `2026-ashconf-when-time-meets-state/when-time-meets-state.pptx` |
| `just export-all` | runs `html`, `pdf` and `pptx` |
| `just clean` | deletes the exported files |

The exported files are ignored by git. The `Slides` GitHub Actions workflow runs `just html` on every push to `main` that touches `slides/`, and publishes the deck to https://team-alembic.github.io/ash_workflow/when-time-meets-state/.

## Code on the slides

`AshWorkflow.DeckDslTest` compiles every AshWorkflow DSL block in `deck.md`, so a slide cannot show an option the library does not have. Each Elixir fence carries a tag in its info string, which Marp does not render:

- `elixir ash_workflow:<fixture>` compiles the block inside a resource supplied by a fixture in `AshWorkflowTest.DeckBlocks`.
- `elixir illustrative` skips the block. Use it for `Ash.Query` pipelines, AshOban triggers, `iex` output and code from other libraries.

An untagged fence fails the test. Run `mix test test/deck_dsl_test.exs` from the project root after editing a code slide.
