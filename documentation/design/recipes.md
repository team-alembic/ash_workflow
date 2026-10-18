# Design: workflow recipes

Status: proposed.

## The problem

Most applications need the same handful of workflows: approval, expiry, publication, invitation. Each team writes them from scratch against the AshWorkflow DSL, and each gets the same details wrong, such as anchoring a deadline on `state_entered_at` when the step can be re-entered.

A recipe is an Igniter task, `mix ash_workflow.gen.<recipe>`, that adds one of these workflows to a subject resource. The generated code belongs to the application from then on. [`approval-recipe.md`](approval-recipe.md) records why recipes generate code instead of injecting it at compile time.

## The catalogue

| Recipe | Steps | Example uses | DSL features exercised |
|---|---|---|---|
| `gen.approval` | `pending → approved \| rejected \| cancelled`, optional `overdue` | Expenses, leave requests, purchase orders | Routed transitions, quorum, resource policies, field-anchored timeout |
| `gen.expiry` | `active → expiring → expired`, with `renew` | Contracts, certifications, licences | `fire_at`, a deadline the application moves |
| `gen.review` | `in_review → changes_requested → in_review → approved` | Content, design review, sign-off | A transition that loops back for revision |
| `gen.publication` | `draft → scheduled → published → unpublished` | Posts, announcements, listings | Two `fire_at` deadlines on one record |
| `gen.invitation` | `sent → accepted \| declined \| expired`, with `resend` | Team invites, RSVPs, access grants | Expiry with a transition that moves the deadline |
| `gen.acknowledgement` | `pending → acknowledged \| overdue` | Policy attestations, terms updates | One row per person per subject |
| `gen.deletion` | `requested → scheduled → deleted`, with `restore` | Account closure, GDPR erasure | Grace-period timeout, `undo` |
| `gen.dormancy` | `active → dormant → archived` | Accounts, projects, leads | `field: :last_activity_at`, an anchor the application writes |
| `gen.verification` | `submitted → verifying → verified \| rejected` | Identity documents, registrations | Automatic step with `on_success`, `on_error` and `retry` |
| `gen.sync` | `pending → syncing → synced \| failed` | CRM push, payment provider, search index | Automatic step with `retry` and backoff |

## Request recipes and lifecycle recipes

Recipes split into two kinds. The kind decides the relationship the generator adds to the subject.

- A request recipe can happen to a subject many times: approval, review, invitation, acknowledgement, verification. The generator adds `has_many` and a `has_one :latest_<recipe>` sorted by `inserted_at` descending.
- A lifecycle recipe describes the one current state of a subject: expiry, publication, deletion, dormancy, sync. The generator adds `has_one` and an identity on `subject_id`.

Both kinds create the subject through `ash.gen.resource` when it does not exist, and both add a boolean calculation to the subject naming the outcome, such as `approved?` or `expired?`.

## Documentation

A recipe is only useful if people find it before they write the workflow by hand. Each recipe gets a page under `documentation/recipes/`, in a new "Recipes" group in the `extras` and `groups_for_extras` of `mix.exs`:

- `documentation/recipes/index.md` lists every recipe in the catalogue above. A recipe that has not landed is listed without a link, so the page shows the whole plan from the first PR.
- `documentation/recipes/<recipe>.md` shows the command, the generated workflow, the state diagram, and the edits the application is expected to make, such as filling in `CanApprove`.

The getting-started tutorial and the README each gain a short "Start from a recipe" section linking to the index. `AshWorkflow.DocumentationDriftTest` adds `documentation/recipes/*.md` to `@doc_files`, so a recipe page that names a removed option fails the build.

## Testing

Each recipe test generates a project, compiles the output, and runs it. Checking the generated source with `=~`, as `Mix.Tasks.AshWorkflow.Gen.TransitionLogTest` does today, proves the text is present but not that it compiles or behaves.

A shared `AshWorkflow.RecipeCase` in `test/support` runs four stages:

1. Build an `Igniter.Test.test_project/1` with fixture files: a domain, an actor resource, and optionally an existing subject resource on `Ash.DataLayer.Ets`.
2. Compose the recipe task with its arguments and `apply_igniter!/1`. Assert there are no issues, and that the expected notices are present.
3. Write every created or changed file into the test's `tmp_dir` and compile them with `Kernel.ParallelCompiler.compile/2`. Assert there are no warnings, so generated code that compiles with a deprecation still fails.
4. Hand the compiled modules to the test body, which drives them through Ash: create a subject, open a request, approve as the wrong actor, approve as the right one, fire the overdue timeout.

Each test module passes a subject name under its own namespace, such as `RecipeFixtures.ApprovalQuorum.Expense`. Compiled modules stay loaded for the rest of the run, so unique names let the tests run with `async: true` without redefining each other's modules.

Every recipe is tested in two cases: an existing subject with attributes and actions of its own, and a missing subject the generator creates. A third test runs the task twice and asserts the second run changes nothing.

Stage 4 fires timeouts the same way the existing timeout tests do, so the overdue deadline is checked against the scheduler rather than by reading the generated `timeout` line.

## The PR stack

Each PR adds one recipe, its page and its tests, and links its row in `documentation/recipes/index.md`. Shared code is extracted in the PR that first needs it twice, not before.

1. `AshWorkflow.RecipeCase`, `documentation/recipes/index.md` and the "Recipes" docs group. `Mix.Tasks.AshWorkflow.Gen.TransitionLogTest` moves onto `RecipeCase`, which gives the harness a real consumer before any recipe exists.
2. `gen.approval`. It also adds a test for a routed transition shared between two steps, which approval relies on and nothing tests today.
3. `gen.expiry`. As the first lifecycle recipe, it extracts the code both kinds share: duration parsing, composing `ash.gen.resource`, and the subject relationship edits.
4. `gen.review`.
5. `gen.publication`.
6. `gen.invitation`.
7. `gen.acknowledgement`.
8. `gen.deletion`.
9. `gen.dormancy`.
10. `gen.verification`.
11. `gen.sync`.

The order after the third PR is a suggestion. Approval and expiry go first because they are the two most different recipes, so the shared code extracted in PR 3 is drawn from both kinds.
