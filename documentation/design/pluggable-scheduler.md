# A pluggable scheduler

## The question

AshWorkflow hardcodes ash_oban. `AshWorkflow.Transformers.AddObanTriggers` is
the only thing that decides when an automatic step runs or a timeout fires. To
allow a scheduler that fires to the millisecond, that decision has to become
someone else's.

Two things need placing: the DSL that selects an implementation, and the
behaviour an implementation satisfies.

## Where the DSL goes

In the `workflow` block, as a module plus its options:

```elixir
workflow do
  scheduler AshWorkflow.Scheduler.Oban, queue: :workflow, check_interval: "* * * * *"

  step :verifying do
    action :run_verification
    on_success :review
  end
end
```

With an application-level default, since most applications pick once:

```elixir
config :ash_workflow, scheduler: {AshWorkflow.Scheduler.Oban, queue: :workflow}
```

Three reasons for the `workflow` block rather than anywhere else.

It is a property of the resource, not of the application. One workflow measured
in days wants cron; another driving a live UI wants milliseconds. The same
application will hold both.

It is where the neighbouring options already live. `queue`, `check_interval` and
`generate_indexes?` are all on `workflow` today, and all three exist only to
configure how work gets run.

It is read at compile time, which is when the decision has to be made. The
implementation contributes to the resource's DSL — Oban triggers, or an
attribute to hold a deadline — so the choice cannot be deferred to runtime.

### What moves under the adapter

`queue` and `check_interval` are Oban concepts sitting at the top level of a
scheduler-agnostic DSL. A cron expression means nothing to a scheduler built on
`Process.send_after/4`. So they become options of the implementation:

| today | proposed |
| --- | --- |
| `queue :workflow` | `scheduler Oban, queue: :workflow` |
| `check_interval "0 * * * *"` | `scheduler Oban, check_interval: "0 * * * *"` |

Both keep working as deprecated aliases that fold into the adapter's options, so
this is not a breaking change on its own.

The per-timeout `check_interval` and `self_scheduled?` stay declared on the
timeout, because they vary per deadline, and reach the implementation in
`Work.opts`. Under a scheduler that fires precisely, `self_scheduled?` stops
meaning anything: the promise it exists to excuse becomes keepable, and
`ValidateTimeoutPrecision` should ask the selected implementation for its floor
rather than assuming 60 seconds.

## The behaviour

`AshWorkflow.Scheduler`. One required callback, three optional ones, and a
function AshWorkflow keeps for itself.

```elixir
@callback transform(Spark.Dsl.t(), [Work.t()], keyword) :: {:ok, Spark.Dsl.t()} | {:error, term}

@callback child_spec(keyword) :: Supervisor.child_spec()
@callback deadline_changed(record, [Work.t()]) :: :ok
@callback cancel(record, [Work.t()]) :: :ok
```

`transform/3` is the declaration point. It runs in a transformer, receives every
`Work` the workflow declared, and returns the DSL state with whatever the
implementation needs added. The Oban implementation adds trigger entities there,
which is `AddObanTriggers` moved behind the behaviour and nothing more.

The optional callbacks are runtime. `child_spec/1` for an implementation holding
an in-memory timeline. `deadline_changed/2` after a record's state changes.
`cancel/2` when a record leaves a step.

### Why `execute/3` is not a callback

`AshWorkflow.Scheduler.execute(work, record, opts)` runs the action and routes
failure to the step's `on_error`. It belongs to AshWorkflow, not to each
implementation.

The scheduler decides *when* work runs and *how durably*. AshWorkflow decides
*what running means*. If `execute/3` were a callback, two implementations could
disagree about whether `on_error` fires, and swapping the scheduler would change
what a workflow does rather than only when it does it.

It also brings that semantics home. `on_error` is an ash_oban trigger option
today, so the meaning of a workflow's error path is expressed in a dependency
that only one implementation uses. `execute/3` puts it in AshWorkflow, where
every implementation gets it — including one with no ash_oban in the tree.

## How one behaviour fits opposite strategies

The sensible implementations work in opposite directions, and this is the part
worth getting right.

A **discovering** scheduler asks the data layer which records match, on an
interval, and records nothing per deadline. Oban is this. Its floor is the
polling interval.

A **registering** scheduler is told each deadline as it becomes known and arms a
timer. Its floor is the timer, which measures in microseconds.

`Work` carries the same fact in both shapes:

```elixir
%Work{
  match: expr(state == :review and state_entered_at <= ago(30, :second)),
  deadline: %{field: :state_entered_at, fire_after: {30, :seconds}}
}
```

`match` selects records eligible now, and is all a discovering implementation
reads — which is why it needs no understanding of timeouts at all. `deadline` is
the rule for computing an exact instant, and is all a registering implementation
reads.

Both point the same way, which is worth spelling out because `ago/2` reads
backwards. `state_entered_at <= ago(30, :second)` means the record entered the
step at least 30 seconds ago, so `match` is false for the first 30 seconds and
true from then on. The deadline instant is `state_entered_at + 30s`. So `match`
becomes true at exactly the moment `deadline` passes, and stays true — it is
"the deadline has lapsed and nothing has happened yet", not "the deadline is
still ahead".

A step has no `deadline`, because it is eligible the moment a record occupies
it: `match` is just `state == :verifying`.

Because `deadline_changed/2` is optional, neither strategy is forced into the
other's shape. A discovering implementation does not implement it. A registering
one gets the hook it needs without every workflow paying for a deadline table —
which is what the review of the stored-pointer design rejected.

## Keeping Oban as the default, adding a precise option

Oban is not being removed. `AshWorkflow.Scheduler.Oban` stays the default a
workflow gets when it says nothing, because a workflow measured in days wants
durability and leader election far more than it wants a precise instant, and
because ash_oban has years of hardening behind its retries, uniqueness, pruning
and testing helpers. What the behaviour adds is an *option* for the workflows
where a minute of latency is the whole problem — a live UI, a countdown, a
market cutoff.

Four steps, each shippable and each leaving the suite green.

1. **Extract.** Add the behaviour and `AshWorkflow.Scheduler.Oban`, whose
   `transform/3` is today's `AddObanTriggers` body. Add the `scheduler` DSL
   option defaulting to it, and move the `AshOban` extension to the resource
   (step 4). Trigger, worker and scheduler module names are unchanged, so
   nothing already enqueued is orphaned.
2. **Add a second.** Done. `AshWorkflow.Scheduler.Precise` registers deadlines
   and arms timers, with the resource as its durable store — a deadline is
   `field + fire_after`, derivable from rows that already exist, which is the same
   property that made `pending_deadlines` a calculation instead of a table.
   `AshWorkflow.Scheduler.Precise.Timeline` holds the timers, and
   `AshWorkflow.Scheduler.notify_state_change/1` is the call site that the
   behaviour was missing: `deadline_changed/2` and `cancel/2` were declared in
   step 1 with nothing invoking them. Two implementations is what actually
   tests the behaviour, and three things only showed up once the second one
   existed.

   `AshWorkflow.Scheduler.execute/3` let a raising change escape past
   `on_error`. `Ash.Changeset.for_update/4` runs an action's changes while
   building the changeset, so an exception surfaces before `Ash.update/2` is
   reached. ash_oban's worker used to catch that, which is exactly the
   semantics step 3 is about moving into AshWorkflow.

   A timer must never fire before its deadline. `Work.match` re-checks the
   deadline in the data layer at fire time, so a timer that runs a fraction of
   a millisecond early reads its own deadline as not yet passed and fires
   nothing. `DateTime.diff/3` truncates toward zero, which is that error, so
   the delay rounds up.

   A test cannot wait for a timer. The timeline fires from its own process,
   which holds no `Ecto.Adapters.SQL.Sandbox` connection, so
   `AshWorkflow.Scheduler.Precise.run_due/2` runs the same work on the
   caller's connection. `Work.match` is what makes that possible without
   duplicating the sweep: it is true exactly when the work is due.
3. **Own the semantics.** Move `on_error`, actor persistence and retry policy
   from ash_oban trigger options into `execute/3` and AshWorkflow's own options,
   so no implementation depends on ash_oban for meaning. The Oban
   implementation keeps passing them down; the point is that AshWorkflow can
   answer what they mean without it.
4. **Move the extension to the resource.** Remove `AshOban` from
   `add_extensions`, and have the resource add it instead:

       extensions: [AshWorkflow, AshOban]

   `add_extensions` is static in `use Spark.Dsl.Extension`, so it cannot be made
   conditional on a DSL option that is read afterwards. Moving it to the
   resource resolves that: the extension goes where the choice is made, and a
   workflow selecting a scheduler unrelated to Oban carries no ash_oban DSL at
   all. `AshWorkflow.Scheduler.Oban` checks for it and fails at compile time
   with the fix in the message.

   This happens in step 1 rather than last, because it is what makes step 2
   possible: without it, a precise implementation could not be written without
   the resource still dragging in ash_oban.

The furthest this goes is `AshWorkflow.Scheduler.Precise` depending on Oban
directly rather than on ash_oban — Oban's durability and `Oban.Peer` are the
parts worth keeping, and ash_oban's trigger codegen is the part a precise
implementation replaces. Even then both adapters ship, and a workflow picks.

## Distribution

A registering implementation holding timers on two nodes fires each deadline
twice. Three ways out, and the third is the recommendation.

Electing a leader of its own means a `:global` name or a Horde registry, so exactly
one node arms timers. This is Oban's `Oban.Peer` reimplemented with none of its
testing, and it still has a failover gap: the deadlines the dead node had armed
are only recovered when the new leader rescans.

Accepting at-least-once means every node arms every timer and the action
absorbs the duplicate. This pushes the hardest part onto
the person writing `action :send_reminder`, and it is exactly the property the
stored-pointer review found AshWorkflow cannot currently supply for action
timeouts — nothing in the row records that a non-repeating timeout fired.

Borrowing Oban's leader keeps its poll as the floor. `Oban.Peer.leader?/2`
already answers "am I the node that runs cluster-singleton work", it is what
`Oban.Stager` gates on, and any application running the default adapter has it
configured. `AshWorkflow.Scheduler.Precise` arms timers only while it holds
leadership, drops them when it loses it, and leaves the ordinary polled trigger
in place underneath at a slow `check_interval`.

That gives the look-ahead structure from the audio detour, with the roles the
right way round:

- The timer is the precision path. It fires on the instant, on one node.
- The poll is the correctness path. If the leader dies mid-deadline, the next
  poll picks the record up, late — which is the right degradation, and the
  behaviour a workflow already has today.
- Firing is a normal generated action, so the atomic `where` re-check that makes
  a stale Oban job cancel with `trigger_no_longer_applies` also makes a
  duplicate timer fire harmless for transition timeouts.

### Taking the peer without the jobs

Leadership is the only thing borrowed. `Oban.Peer` documents this use — "you can
use peer leadership to extend Oban with custom plugins, or even within your own
application" — and none of the job side is involved: no queue, no worker, no
`Oban.Job` row, no `Oban.Cron`. `AshWorkflow.Scheduler.Precise` arms its own
timers and calls its own actions.

That dependency belongs behind its own one-callback behaviour, so the precise
adapter is not hard-wired to Oban either:

```elixir
defmodule AshWorkflow.Scheduler.Leader do
  @callback leader?(keyword) :: boolean
end
```

`Leader.Oban` delegates to `Oban.Peer.leader?/2`. `Leader.Single` returns `true`,
which is what a single-node deployment and every test wants. A lease-table
implementation with no Oban at all can land later without touching `Precise`.

An application already running the default adapter has a peer configured, so
`leader: {Leader.Oban, name: Oban}` costs it nothing. An application that runs no
jobs starts an instance that holds only the peer:

```elixir
{Oban, name: AshWorkflow.Peer, repo: MyApp.Repo, queues: [], plugins: [], stager: false}
```

Four things about that are worth writing down, because three of them are traps.

`plugins: []`, not `plugins: false`. `Oban.Config.normalize_peer/1` replaces the
peer with `{Oban.Peers.Isolated, leader?: false}` when `plugins` is `false`, so
that instance would never lead and every deadline would be armed by nobody.

`testing: :manual` and `testing: :inline` do the same thing, for the same reason.
So leadership is always false under test, and the test config has to select
`Leader.Single` — which is the behaviour's first real job.

`Oban.Peers.Database` needs the `oban_peers` table and a running
`Oban.Notifier` under the instance name, since it calls
`Notifier.listen(conf.name, :leader)` to hear a departing leader stand down. That
is why this starts an Oban instance rather than the peer module on its own, and
it means Oban's migrations are still a requirement even with no queues.

A distinct instance name gets its own row in `oban_peers`, so it never contends
with the application's main Oban leadership. The two can elect different nodes.
That is fine — the requirement is exactly one arming node, not the same one Oban
picked.

The cost is Oban staying in the tree for the precise adapter, plus a handful of
processes and a leadership query every 30 seconds. Worth naming what the
alternative costs: a precise scheduler that borrows leader election is ~200
lines, and one that owns it is a distributed-systems project.

**Still open.** Action timeouts under a duplicate fire. The `where` re-check
saves transition timeouts because the state change is the durable record that it
fired; a `timeout :reminder, action: :send_reminder` has no such marker, so two
nodes racing during a leadership handover can send it twice. Either the precise
adapter refuses action timeouts, or the fired-state question the stored-pointer
review raised gets answered first. This should be settled before `Precise` is
recommended for more than one node.
