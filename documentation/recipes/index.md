# Recipes

A recipe is a Mix task that adds a common workflow to one of your resources, such as an approval or an expiry. Run `mix ash_workflow.gen.<recipe>` with the resource to attach it to, and the task writes the workflow resource, its relationship to your resource, and the actions it needs.

The generated code belongs to your application. Edit it like any other code you wrote: rename steps, change deadlines, and fill in the policy checks. AshWorkflow does not regenerate the code or keep it in step with later versions of the recipe.

## Catalogue

A recipe without a link has not been released yet. Each row links to its page once the recipe is available.

| Recipe | Steps | Example uses |
|---|---|---|
| [`gen.approval`](approval.md) | `pending → approved \| rejected \| cancelled`, optional `overdue` | Expenses, leave requests, purchase orders |
| [`gen.expiry`](expiry.md) | `active → expiring → expired`, with `renew` | Contracts, certifications, licences |
| `gen.review` | `in_review → changes_requested → in_review → approved` | Content, design review, sign-off |
| `gen.publication` | `draft → scheduled → published → unpublished` | Posts, announcements, listings |
| `gen.invitation` | `sent → accepted \| declined \| expired`, with `resend` | Team invites, RSVPs, access grants |
| `gen.acknowledgement` | `pending → acknowledged \| overdue` | Policy attestations, terms updates |
| `gen.deletion` | `requested → scheduled → deleted`, with `restore` | Account closure, GDPR erasure |
| `gen.dormancy` | `active → dormant → archived` | Accounts, projects, leads |
| `gen.verification` | `submitted → verifying → verified \| rejected` | Identity documents, registrations |
| `gen.sync` | `pending → syncing → synced \| failed` | CRM push, payment provider, search index |
