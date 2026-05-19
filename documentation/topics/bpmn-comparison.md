# Comparison to BPMN 2.0

Teams adopting AshWorkflow often arrive with a BPMN mental model from Camunda, Zeebe, or Flowable. This page maps that vocabulary onto what AshWorkflow and [Reactor](https://hexdocs.pm/reactor) actually give you, and is direct about where the model stops. It's the page to read if you're deciding between "build it on AshWorkflow + Reactor" and "stand up a BPMN engine".

## Three different execution shapes

The two libraries and BPMN are not three flavours of the same thing. They are three different runtime shapes:

- **Reactor** is a DAG saga executor. Inputs flow through a directed graph of steps that resolve dependencies, run concurrently when they can, and compensate or undo on failure. Execution is in-memory and one-shot.
- **AshWorkflow** is a persistent finite-state machine. A record sits in one `state` at a time. Transitions are Ash update actions. Automatic steps and timeouts fire via Oban cron polling. Persistence comes from the host resource's data layer.
- **BPMN** is a token-flow graph over a persistent process instance. Multiple tokens can be live at once. External events (messages, signals, timers, errors) arrive mid-flight and get correlated to waiting catch points. The whole instance is event-sourced and migratable.

AshWorkflow and Reactor cover **disjoint slices** of BPMN. Reactor is rich at the small-scale DAG layer; AshWorkflow is rich at the long-running durable layer. Neither bridges to the parts of BPMN that depend on inbound message correlation, multiple concurrent tokens per instance, or durable resumable continuations across waits.

## What's covered well

| BPMN concept | Where it lives in this stack |
| --- | --- |
| Service Task | Reactor `run` / `Ash.Reactor` action steps, or AshWorkflow automatic `step ... action:` |
| User Task (basic state + authorization) | AshWorkflow manual `step` + named `transition`, with step-level `policy` blocks (see [Authorization](authorization.md)) |
| Sequence flow with conditions | AshWorkflow `transition ... route ... when: expr(...)`, Reactor `switch` |
| Exclusive (XOR) gateway | Reactor `switch` with `matches?`/`default`, or AshWorkflow conditional routes |
| Parallel (AND) split + join | Reactor's implicit DAG — steps with no dependencies fan out; a downstream step depending on N predecessors *is* the join |
| Multi-instance parallel / sequential | Reactor `map` step (`async?` flag controls parallelism) |
| Call Activity | Reactor `compose` step embeds a sub-reactor as a single step |
| Per-step saga compensation | `Reactor.Step.compensate/4` + `undo/4`, with `backoff/4` for retry delay |
| Retries with backoff | Reactor `max_retries`, custom backoff strategies (exponential, jitter, `Retry-After`) |
| Process instance persistence | The host Ash resource *is* the instance — durable via its data layer |
| Timer Start Event (cycle) | AshWorkflow `timeout` with a `check_interval` cron (see [Timeouts and deadlines](timeouts-and-deadlines.md)) |
| Authorization on user-task completion | AshWorkflow step `policy` generates Ash policies on the transition action |
| Code interface | AshWorkflow generates `Resource.approve(record)` style functions, equivalent to engine command APIs |
| Process introspection | `AshWorkflow.Info` exposes `current_step`, `available_actions`, `steps`, the workflow graph |
| Audit trail | Composable via AshPaperTrail on the host resource — not built in |

## Partial coverage

These work, but with edges worth knowing.

### Timers

AshWorkflow `timeout` is implemented as Oban cron polling — `add_oban_triggers.ex` builds an `AshOban.Trigger` with `scheduler_cron: timeout.check_interval`, default `* * * * *`. That fits "remind after two days" and "escalate if stuck overnight". It is **not** a per-instance scheduled-job queue with precise `timeDate` / `timeDuration` firing at the second granularity, and there are **no intermediate timer catch events** mid-flow — only timeouts attached to a state.

### Errors and retries

Reactor handles step-local errors well: compensation, retry with backoff, `:continue` fallback. What's missing is **BPMN-style error propagation up the lexical scope chain** (sub-process → parent → call-activity caller, until a boundary error event catches it). Reactor failure is local; Ash.Reactor errors surface as Ash errors, not as a navigable scope tree.

There is also no process-instance-keyed "incidents" surface — failed Oban jobs go to the Oban dashboard, not a view that says "instance #5421 is blocked on this step, retry / resolve / skip".

### Sub-processes and scopes

Reactor `compose` covers **Call Activity** cleanly. It does not cover:

- **Embedded sub-process** with shared mutable variable scope (Reactor results are immutable values passed as inputs to children).
- **Event sub-process** — a sub-process started by an internal event (message arriving, error thrown, timer firing, signal received).
- **Transaction sub-process** with cancel-end-event semantics. Reactor's `undo/4` is closer to "always rollback on failure" than to "cancel this transaction explicitly and compensate everything that finished inside it".

### Human-task lifecycle

AshWorkflow gives you the *state* of "waiting for a human" and *who is permitted to act* (via policies). It does not give you the WS-HumanTask lifecycle: `created → ready → reserved/claimed → in-progress → completed`, with claim / unclaim / delegate / escalate, candidate users versus candidate groups, priority, due date as a task attribute. All of that is modellable on top of an Ash resource — none of it is generated by the DSL.

### Multi-instance completion condition

Reactor `map` handles parallel and sequential multi-instance. BPMN additionally supports a `completionCondition` predicate that terminates remaining siblings early ("three of five reviewers approve, cancel the other two"). That early-exit hook is not built in.

### Gateway types

AshWorkflow conditional routes use first-match semantics — `lib/ash_workflow/changes/conditional_transition.ex` uses `Enum.reduce_while` and halts on the first `{:ok, true}`. That's exclusive (XOR). There is no **inclusive (OR) gateway** that fires every matching branch and joins on the as-fired set, and no **event-based gateway** that races multiple catching events.

## What's missing structurally

These aren't bug-list items. They're architectural absences — features that would need substantial new infrastructure to add.

1. **Message correlation.** No inbound channel keyed by `(messageName, correlationKey)`. The Ash way to "send a message to a waiting workflow" is to call an action against a specific record — that's already correlation by primary key, but it isn't *named messages* with subscriptions and a correlation key separate from PK.
2. **Signal broadcast.** No native fan-out to every subscribed waiting catch event. The natural Elixir fit would be Phoenix.PubSub plus action triggers per subscriber, but it isn't in either library.
3. **Event-based gateway.** No "first event wins" race point. Reactor's `switch` is data-driven, not event-driven.
4. **Boundary events on running activities.** Both interrupting and non-interrupting variants — "if a timer fires or a message arrives while this activity runs, cancel it (or fork a parallel branch) and route along the boundary edge". AshWorkflow `timeout` is scoped to a *state*, not to an *in-flight activity execution*. Reactor has no notion of attaching events to a running step. **This is the single biggest missing primitive for BPMN parity.**
5. **Concurrent tokens within one instance.** AshWorkflow is single-token by construction — a record holds one `state` value. BPMN allows many parallel tokens in one instance (AND-split, multi-instance, event sub-processes, non-interrupting boundaries). You can model that with child records, but it's not BPMN-shaped.
6. **Durable resumable continuations.** Reactor runs in memory; a week-long approval can't be a paused Reactor. AshWorkflow persists between *states*, but advances from one to the next via Oban-triggered actions, not by resuming a paused graph.
7. **Compensation as a separate flow.** Reactor `undo/4` is saga rollback when a later step fails. BPMN's compensation is an explicit `compensateThrow` event that walks the log of *completed* activities in reverse, invoking each one's registered handler — and can be thrown from arbitrary points, including against successful sub-processes.
8. **Process versioning and live-instance migration.** No story for "instance is on workflow v1, deploy v2 with a renamed step, migrate the running instance's `state`". One of the two killer ops features of mature BPMN engines.
9. **Operator cockpit.** No instance inspector, no incident dashboard, no token-position visualizer, no modification API to move a running instance's position, no per-instance suspend/resume. Pieces exist (Oban Web, AshAdmin), but nothing instance-shaped.
10. **DMN business-rule tasks.** Out of scope for the Elixir ecosystem at this level of polish.
11. **Job worker / external task pattern.** Zeebe-style cross-language pull workers. Oban is in-VM; cross-runtime job distribution would need to be built.

### Why these gaps come as a package

The structural gaps don't decouple. Solving event-driven catching properly forces per-instance subscription state, which forces multi-token semantics (because non-interrupting catches spawn parallel branches), which forces durable continuations across waits (because tokens can be paused indefinitely between events). The "event correlation + concurrent tokens + resumable persistence" cluster is the BPMN runtime, and you don't get one without the others.

## Rough coverage

BPMN feature counting is inherently fuzzy — engines disagree about which constructs are required — but in round numbers, against the *executable* subset:

- **Reactor alone**: around 40%. Strong on service tasks, gateways, multi-instance, call activity, compensation. Missing everything event-driven and everything durable.
- **AshWorkflow alone**: around 30%. Strong on user tasks, persistence, timer starts, authorization. Missing parallel tokens, all event-correlation, rich error semantics.
- **Both wired together** (Reactor running inside an AshWorkflow transition's Ash action): around 55%. The two engines don't share a token model, so cross-cutting features (boundary event on a running reactor, compensation across a transition + a reactor) don't compose naturally.

## When this stack is enough

- Long-running domain processes with clear states and human approvals → AshWorkflow.
- Multi-step service orchestrations with retries and compensation → Reactor.
- Both wired together → most CRUD-flavoured workflows where each state has a clear action and the inter-step coordination is "next state on success, error state on failure".

Reach for a BPMN engine if you need:

- Arbitrary inbound message correlation by named message + correlation key.
- True parallel tokens within one instance with selective join semantics.
- Runtime migration of in-flight instances across workflow versions.
- An operator cockpit for monitoring, modification, and incident resolution.
- DMN business-rule integration.
- Cross-language pull workers picking jobs off a central broker.

## Reference

The claims above are grounded in the following files. If you want to verify a specific assertion, these are the places to read:

- `lib/ash_workflow.ex` — DSL extension root and entity declarations
- `lib/ash_workflow/entities/step.ex`, `transition.ex`, `timeout.ex`, `route.ex` — DSL entities
- `lib/ash_workflow/transformers/add_state_machine.ex` — AshStateMachine wiring (single-token model)
- `lib/ash_workflow/transformers/add_oban_triggers.ex` — `scheduler_cron`-based timer and auto-step firing
- `lib/ash_workflow/changes/conditional_transition.ex` — first-match conditional routing
- `lib/ash_workflow/info.ex` — runtime introspection API

For Reactor itself see [`hexdocs.pm/reactor`](https://hexdocs.pm/reactor) and the `Reactor.Step`, `Reactor.Builder`, `Reactor.Middleware` modules in particular.
