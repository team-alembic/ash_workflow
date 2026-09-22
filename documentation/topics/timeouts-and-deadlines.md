# Timeouts and Deadlines

Timeouts let you react to a workflow being stuck in a state. They're useful for reminders, escalations, SLA enforcement, and offer expirations.

For a recurring action that runs on an interval for as long as a record stays in a step, see [Recurring actions with `every`](#recurring-actions-with-every) below — it is a separate entity from `timeout`, not an option on it.

## How timeouts work

Each timeout becomes an Oban trigger that polls on a cron schedule (default: every minute). The trigger's `where` clause checks both the state and a datetime field (default: `state_entered_at`):

```
where: state == :step_name and <field> <= ago(duration)
```

Once the condition is met, the trigger fires the timeout's action. When the workflow leaves the state (via a manual transition or another timeout), the `where` clause stops matching and the trigger naturally stops firing. The `field` can be overridden per timeout — see [Data-driven deadlines](#data-driven-deadlines-with-field) below.

## Action timeouts

Action timeouts run an Ash action without changing state. Use them for reminders, notifications, or logging:

```elixir
step :awaiting_response do
  transition :respond, to: :next_step

  timeout :reminder, fire_after: {3, :days}, action: :send_reminder
end
```

You define the action with your notification logic:

```elixir
actions do
  update :send_reminder do
    accept []
    change MyApp.Changes.SendReminderEmail
  end
end
```

## Transition timeouts

Transition timeouts force the workflow into a new state. Use them for escalations, expirations, or SLA breaches:

```elixir
step :awaiting_review do
  transition :approve, to: :approved

  timeout :escalation, fire_after: {7, :days}, transition_to: :escalated
end

step :escalated, terminal: true
```

The extension generates a hidden update action (`:__timeout_review_escalation` — `__timeout_<step>_<name>`) that performs the state transition. You don't need to define this action yourself. Because the name includes the step, several steps can each declare an `:escalation` timeout of their own.

## Recurring actions with `every`

A timeout fires once. For an action that keeps firing on an interval for as long as the workflow remains in a step, use `every` instead — it is a sibling entity to `timeout`, declared inside the same `step` block:

```elixir
step :awaiting_response do
  transition :respond, to: :next_step

  # Fires once after 3 days
  timeout :reminder, fire_after: {3, :days}, action: :send_reminder

  # Fires after 3 days, then every 3 days while still waiting
  every :follow_up do
    interval {3, :days}
    action :send_follow_up
  end
end
```

`every` always requires `action` — there is no `transition_to`, because firing never leaves the step. That is the reason it exists as its own entity rather than a `repeat: true` flag on `timeout`: a timeout with both `repeat: true` and `transition_to` would be meaningless, since leaving the step stops the repeat before it ever comes round.

Each time `every`'s action runs, the extension resets `state_entered_at` to the current time. This restarts the interval — so `interval: {3, :days}` means the action fires every 3 days, not on every scheduler cycle.

This reset is why `state_entered_at` is a timer anchor rather than a reliable "when did we enter this state" fact — a workflow that's been waiting for nine days with reminders every two reports `state_entered_at` as two days ago. If you need the honest answer, see [Workflow history](workflow-history.md), which adds an `entered_current_state_at` calculation that ignores these resets.

A timeout never resets `state_entered_at` and uses Oban's `trigger_once?` to prevent re-firing after the action completes. Resetting it would push every other deadline on the same step back by the same amount, so a `timeout :warn, fire_after: {30, :minutes}, action: :warn` cannot delay the `timeout :breach, fire_after: {1, :hours}, transition_to: :escalated` beside it. A transition timeout (with `transition_to`) doesn't need either mechanism, since the state change naturally prevents re-firing.

### Bounding `every` with `until`

`every` alone fires forever. `until` stops it after a fixed amount of wall-clock time:

```elixir
every :reminder do
  interval {2, :days}
  action :send_review_reminder
  until {8, :days}
end
```

This fires roughly at day 2, day 4 and day 6, then stops before day 8. Three reminders, then silence, not four: the last fire has to land strictly before `until`, and polling lag pushes each one slightly later than its nominal day. `AshWorkflow.Verifiers.ValidateEvery` rejects an `until` that is not strictly longer than `interval`, since anything shorter or equal leaves no room for even one fire.

`until` is not measured against `state_entered_at`, the same attribute `interval` measures against and resets on every firing — a bound checked against it would never be reached. It is measured against `repeat_started_at`, an attribute the extension adds when some `every` declares `until`. Every genuine step entry writes it to the same instant as `state_entered_at`: a manual transition, an automatic step completing, a transition timeout, an undo, or the initial create. An `every`'s own firing resets `state_entered_at` to re-arm itself, and never touches `repeat_started_at` — so it answers "when did the record enter this step", immune to the resets `state_entered_at` cannot avoid.

Reaching `until` only stops the firing. It does not transition state, and it fires no notification of its own. The record stays in the step, silent, until something else moves it. If you also want a transition once reminders run out, declare it as a second, ordinary timeout rather than looking for a bound-triggered transition:

```elixir
step :awaiting_response do
  every :reminder do
    interval {2, :days}
    action :send_review_reminder
    until {8, :days}
  end

  timeout :give_up, fire_after: {8, :days}, transition_to: :escalated
end
```

The two share nothing at runtime. `give_up` is exactly the transition timeout described in [Transition timeouts](#transition-timeouts) above, just given a `fire_after` equal to the bound. Composing two this way keeps `until` doing one thing rather than growing a second, transition-shaped meaning.

`until` bounds wall-clock time, not a count of firings. A workflow that wants to say "at most 4 reminders" rather than "for at most 8 days" needs a firing counter, which is a different feature. Nothing here tracks how many times an `every` has fired, only when it started. See `documentation/design/every-until.md` for the alternatives considered, including why the bound is not measured against a per-record anchor of its own the way a timeout's `field` can be.

## Data-driven deadlines with `field`

By default, timeouts measure duration against `state_entered_at` — when the workflow entered its current state. The `field` option lets you measure against any datetime attribute or calculation instead:

```elixir
step :active do
  transition :deactivate, to: :inactive

  # Fires 3 months after the worker's last session, not after entering :active
  timeout :inactivity do
    fire_after {3, :days}
    field :last_session_date
    transition_to :inactive_review
  end
end
```

The generated Oban trigger checks `last_session_date <= ago(3, :day)` instead of `state_entered_at <= ago(3, :day)`. The field must be an existing attribute or calculation on the resource — a compile-time error is raised if it doesn't exist.

Use cases include:
- **Worker inactivity**: `field: :last_session_date` — timeout based on actual activity
- **Document expiry**: `field: :earliest_cert_expiry` — notify before certs expire
- **SLA tracking**: `field: :committed_by_date` — alert when a deadline approaches

> #### `every` has no `field` option {: .warning}
>
> `every` resets `state_entered_at` to restart the interval. With a custom field, this reset would need to update that field to "now" — but that's semantically wrong. If `field: :last_session_date`, resetting it to "now" would falsely claim a session occurred. So `every` always measures against `state_entered_at`, and cannot be pointed at a custom field the way `timeout` can.
>
> A timeout against a custom field is not a periodic check. Its trigger keeps matching while the condition holds, but `trigger_once?` stops the action running a second time for the same record, so the reminder fires once. For a genuinely periodic check, add the cadence to the field itself — advance `:next_check_at` in the timeout action — so the condition stops matching until the next window opens.

### Durations are constants, anchors are not

`fire_after` and `until` take a literal duration tuple. Neither takes an Ash expression, so there is no way to write "fire a number of days that this record carries in a column". The dynamism goes in a timeout's anchor instead: point `field` at an attribute or an expression calculation, and leave the duration fixed. When the record already carries the deadline instant rather than a delay, name it with `fire_at` and skip the offset entirely.

```elixir
# Each record carries its own delay, folded into the anchor
calculate :respond_by, :utc_datetime_usec,
          expr(datetime_add(state_entered_at, response_sla_seconds, :second))

timeout :chase do
  fire_after {1, :minutes}   # "once respond_by has passed"
  field :respond_by
  action :chase_response
end
```

Two things break if the duration itself becomes an expression, and only one of them is about speed.

`AshWorkflow.Verifiers.ValidateTimeoutPrecision` compares the duration against the selected scheduler's floor at compile time, and rejects a deadline the scheduler cannot honour. An expression has no value to compare, so that check stops existing and the DSL can promise a precision cron cannot keep.

A literal also reaches Postgres as a bind parameter, so a timeout's `where` clause is `state = $1 AND state_entered_at <= $2`, which the `(state, field)` index from `AshWorkflow.Transformers.AddIndexes` serves as a range scan. `AshWorkflow.Scheduler.Precise.Timeline` computes its horizon bound in Elixir for the same reason. A per-row duration turns both into a computed comparison, and the index stops helping.

`AshWorkflow.Scheduler.due_at/2` and the `pending_deadlines` calculation would also have to evaluate the expression per record to produce an instant, rather than doing the arithmetic directly.

The anchor pays none of that. It is a column or an expression the data layer already knows how to compute, the duration beside it stays checkable and indexable, and the two compose to the same deadline. `every` has no anchor to point anywhere — it always measures against `state_entered_at` — so this dynamism is not available to `interval` or `until` at all; see [`every` has no `field` option](#every-has-no-field-option) above.
## Firing at an instant a field already holds with `fire_at`

`field` is the anchor `fire_after` measures an offset from. When the field already holds the deadline instant, there is no offset to measure, and `fire_at` names the field directly:

```elixir
step :dormant do
  timeout :review do
    fire_at :next_check_at
    transition_to :dormant_review
  end
end
```

The generated trigger checks `next_check_at <= now()`. The timeout fires once that instant has passed, at whatever resolution the selected scheduler polls with, so `AshWorkflow.Scheduler.Oban` fires it within a minute of the instant and `AshWorkflow.Scheduler.Precise` arms a timer for it.

`fire_at` takes a datetime attribute or an expression calculation, checked at compile time exactly as `field` is. `fire_at` and `fire_after` are mutually exclusive and exactly one is required, and `fire_at` cannot be combined with `field`.

`fire_at` belongs to `timeout` alone. An `every` declares an `interval` and measures it against `state_entered_at`, so there is no deadline field for `fire_at` to name.

Before `fire_at` existed, the way to express this was `fire_after: {1, :seconds}` against the deadline field, since `AshWorkflow.Duration.validate/1` requires a positive integer and there was no way to say "no offset". Use `fire_at` instead. The sentinel handed `AshWorkflow.Verifiers.ValidateTimeoutPrecision` a duration that meant nothing, and that verifier now skips a `fire_at` timeout: a timeout that promises no duration cannot promise a precision the scheduler misses.

`fire_at` pairs with the periodic-check pattern described above. A timeout action that advances `:next_check_at` to the next window stops the condition matching until that window opens.

```elixir
step :monitoring do
  timeout :check do
    fire_at :next_check_at
    action :run_check
  end
end
```

`AshWorkflow.Scheduler.due_at/2` reads the deadline field off the record with `Map.get/2`, which finds `%Ash.NotLoaded{}` for a calculation nobody loaded, and returns `nil` for it. `AshWorkflow.Scheduler.Precise.Timeline` loads a calculation deadline field with the records it sweeps, so a `fire_at` calculation arms a timer there. A caller computing `due_at/2` from a record of its own has to load the calculation first, which is [issue #70](https://github.com/team-alembic/ash_workflow/issues/70).

## Duration units

Supported units: `:seconds`, `:minutes`, `:hours`, `:days`.

```elixir
timeout :hourly_ping, fire_after: {1, :hours}, action: :send_ping
timeout :weekly_expire, fire_after: {7, :days}, transition_to: :expired
```

### Shorter than a poll interval

The shortest deadline you can declare comes from the scheduler you selected.
`AshWorkflow.Scheduler.Oban` is the default and polls on a cron interval, and
cron cannot poll more often than once a minute, so `fire_after: {30, :seconds}`
would fire up to 60 seconds late — an error larger than the deadline itself.
`AshWorkflow.Verifiers.ValidateTimeoutPrecision` rejects it at compile time
rather than making a promise the scheduler cannot keep.

For a deadline shorter than a minute, select the scheduler that arms a timer
per deadline instead of polling:

```elixir
workflow do
  scheduler AshWorkflow.Scheduler.Precise

  step :awaiting_confirmation do
    # Fires 30 seconds later, not up to 60 seconds after that
    timeout :quick_check, fire_after: {30, :seconds}, action: :check_status
  end
end
```

Then start the process that holds the timers, listing the resources it
recovers deadlines for:

```elixir
children = [
  {AshWorkflow.Scheduler.Precise.Timeline, resources: [MyApp.Order]}
]
```

See `AshWorkflow.Scheduler.Precise` for what that trades away. A timer lives in
memory, so a deadline held only by a timer is lost when the node dies and is
recovered by the look-ahead sweep on whichever node leads next. A workflow
measured in days wants Oban's durability more than an exact instant.

If you would rather keep the polling scheduler and drive one timeout yourself,
`self_scheduled?: true` asserts that something else invokes it at the
resolution the deadline needs:

```elixir
# Nothing polls for this one. Call AshOban.schedule/2, or drive it from your
# own process, as often as the deadline requires.
timeout :quick_check do
  fire_after {30, :seconds}
  action :check_status
  self_scheduled? true
end
```

## Polling interval and precision

Timeouts are not scheduled jobs waiting to fire at a particular time. Each one
is an Oban cron scheduler that wakes on an interval, queries for records whose
deadline has passed, and enqueues work for the ones it finds. The interval is
`check_interval`, and it defaults to every minute (`"* * * * *"`).

Set it once for the whole resource, and override individual timeouts that need
a different cadence:

```elixir
workflow do
  # Every trigger on this resource polls hourly instead of every minute
  check_interval "0 * * * *"

  step :awaiting_review do
    transition :approve, to: :approved

    # Inherits the hourly interval above
    timeout :nudge, fire_after: {2, :days}, action: :send_nudge

    # Overrides it: checked once a day at 9am
    timeout :daily_report do
      fire_after {3, :days}
      action :generate_report
      check_interval "0 9 * * *"
    end
  end
end
```

### What polling costs

The workflow-level `check_interval` applies to **automatic step triggers,
timeouts and `every` entities alike**, and each one gets its own scheduler.
That means the cost multiplies with the size of the workflow, not with the
number of records:

| Triggers on the resource | Default interval | Scheduler queries per hour |
|---|---|---|
| 4 automatic steps + 4 timeouts | `"* * * * *"` | 480 |
| 4 automatic steps + 4 timeouts | `"0 * * * *"` | 8 |

Each of those queries is a filtered read against the resource's table, so they
are individually cheap and well served by an index on `state`. But they run
whether or not any record is actually waiting, on every resource that uses
AshWorkflow, forever.

The default of every minute suits deadlines measured in minutes or hours. For
workflows measured in days — most approval and onboarding flows — an hourly or
daily interval gives the same user-visible behaviour for a fraction of the
queries. Match the interval to the precision the deadline actually needs:

```elixir
# A 14-day offer expiry does not need minute precision
workflow do
  check_interval "0 * * * *"
  # ...
end
```

> #### Timeouts are not precise to the second {: .info}
>
> A timeout fires on the first scheduler cycle *after* the duration has elapsed. With the default every-minute cron, a `{2, :days}` timeout fires somewhere between exactly 2 days and 2 days + 1 minute after `state_entered_at`. If you set `check_interval: "0 * * * *"` (hourly), the window is up to 1 hour.
>
> Do not try to close that window with a faster cron. `AshWorkflow.Verifiers.ValidateTimeoutPrecision` rejects a deadline shorter than a minute on the polling scheduler, because cron does not poll below that. For sub-minute precision select `AshWorkflow.Scheduler.Precise`, or set `self_scheduled?: true` on the one timeout you drive yourself. See [Shorter than a poll interval](#shorter-than-a-poll-interval) above.

## Oban queue configuration

By default, all workflow triggers use the `:workflow` queue. You can override this at the workflow level:

```elixir
workflow do
  queue :hiring_pipeline

  step :process, action: :run_processing, on_success: :review
  # ...
end
```

All generated triggers (automatic steps and timeouts) will use the specified queue.

> #### Queue must be configured in Oban {: .warning}
>
> The queue name must match a queue in your Oban configuration. If the queue isn't configured, jobs will be inserted but never executed — they'll sit in the `oban_jobs` table indefinitely with no error. This is validated at runtime by Oban, not at compile time.

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10, hiring_pipeline: 5]
```

## The `state_entered_at` attribute

The extension auto-adds a `state_entered_at` (`utc_datetime_usec`) attribute to the resource. It's set when the record is created and updated every time the state changes on manual transitions and automatic step completions. Timeout durations are calculated from this timestamp.

If you need to define this attribute yourself (e.g., with a custom default or source), the extension skips adding it.
