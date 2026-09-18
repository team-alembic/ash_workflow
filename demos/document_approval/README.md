# Document approval

Two administrators must sign off a document before it publishes.

The point of this demo is that **`:approve` is a single action that does not
always advance the workflow**. Its destination is chosen at runtime by
conditional routes:

```elixir
transition :approve do
  route :approved, when: expr(not is_nil(first_approver_id))
  route :in_review, when: expr(is_nil(first_approver_id))
end
```

Route conditions are evaluated against the record *before* the update is
applied. So the first approver sees `first_approver_id` as `nil` and loops back
to `:in_review`; the second sees it set and completes the document. One action,
two outcomes, no extra states to manage.

## The flow

```
drafting ──(submit)──▶ validating ──▶ in_review ──(approve)──▶ in_review
                            │             │          (first signature)
                            │             ├─(approve)──▶ approved
                            │             │          (second signature)
                            │             ├─(reject)───▶ rejected
                            │             ├─ every 2 days ──▶ nudge
                            │             ╰─ 14 days ─▶ expired
                            ╰──on_error──▶ validation_failed
```

## What it demonstrates

| Feature | Where |
|---|---|
| Conditional routes (`route ... when:`) | the two-signature `:approve` |
| Business logic on a *generated* transition action | `update :approve` is declared explicitly, and AshWorkflow merges its transition into it |
| Automatic step with `on_error` | `:validating` routes short documents to `:validation_failed` |
| Step-level policies | only `role: :admin` may approve or reject |
| Repeating timeout | the review nudge, which fires once per interval |
| Transition timeout | unreviewed documents expire after 14 days |
| Tuned `check_interval` | sign-off is measured in hours, so the resource polls every 5 minutes rather than every minute |

"A different administrator must sign" is business logic, not workflow shape, so
it lives in a change (`Document.RecordApproval`) rather than in the DSL.

## Running it

Needs PostgreSQL. Connection details come from `POSTGRES_HOST`, `POSTGRES_PORT`,
`POSTGRES_USER` and `POSTGRES_PASSWORD`, defaulting to
`postgres:postgres@localhost:5432`.

```bash
mix deps.get
mix test
```
