# Timeouts and Deadlines

Timeouts let you react to a workflow being stuck in a state. They're useful for reminders, escalations, SLA enforcement, and offer expirations.

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

  timeout :reminder, after: {3, :days}, action: :send_reminder
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

  timeout :escalation, after: {7, :days}, transition_to: :escalated
end

step :escalated, terminal: true
```

The extension generates a hidden update action (`:__timeout_review_escalation` — `__timeout_<step>_<name>`) that performs the state transition. You don't need to define this action yourself. Because the name includes the step, several steps can each declare an `:escalation` timeout of their own.

## Repeating timeouts

By default, action timeouts fire once. Set `repeat: true` to keep firing on every scheduler cycle while the workflow remains in that state:

```elixir
step :awaiting_response do
  transition :respond, to: :next_step

  # Fires once after 3 days
  timeout :reminder, after: {3, :days}, action: :send_reminder

  # Fires after 3 days, then on every check_interval while still waiting
  timeout :follow_up, after: {3, :days}, action: :send_follow_up, repeat: true
end
```

When a repeating timeout fires, the extension resets `state_entered_at` to the current time. This restarts the duration window — so `after: {3, :days}` means the action fires every 3 days, not every scheduler cycle.

Non-repeating timeouts (the default) use Oban's `trigger_once?` to prevent re-firing after the action completes. Transition timeouts (with `transition_to`) don't need either mechanism since the state change naturally prevents re-firing.

## Data-driven deadlines with `field`

By default, timeouts measure duration against `state_entered_at` — when the workflow entered its current state. The `field` option lets you measure against any datetime attribute or calculation instead:

```elixir
step :active do
  transition :deactivate, to: :inactive

  # Fires 3 months after the worker's last session, not after entering :active
  timeout :inactivity, after: {3, :days},
    field: :last_session_date,
    transition_to: :inactive_review
end
```

The generated Oban trigger checks `last_session_date <= ago(3, :day)` instead of `state_entered_at <= ago(3, :day)`. The field must be an existing attribute or calculation on the resource — a compile-time error is raised if it doesn't exist.

Use cases include:
- **Worker inactivity**: `field: :last_session_date` — timeout based on actual activity
- **Document expiry**: `field: :earliest_cert_expiry` — notify before certs expire
- **SLA tracking**: `field: :committed_by_date` — alert when a deadline approaches

> #### `repeat: true` is not supported with custom fields {: .warning}
>
> Repeating timeouts reset `state_entered_at` to restart the duration window. With a custom field, this reset would need to update that field to "now" — but that's semantically wrong. If `field: :last_session_date`, resetting it to "now" would falsely claim a session occurred. The extension rejects this combination at compile time.
>
> If you need periodic checks against a custom field, use a non-repeating timeout. The Oban trigger will keep matching on every poll cycle as long as the condition holds.

## Duration units

Supported units: `:seconds`, `:minutes`, `:hours`, `:days`.

```elixir
timeout :quick_check, after: {30, :seconds}, action: :check_status
timeout :hourly_ping, after: {1, :hours}, action: :send_ping
timeout :weekly_expire, after: {7, :days}, transition_to: :expired
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
    timeout :nudge, after: {2, :days}, action: :send_nudge

    # Overrides it: checked once a day at 9am
    timeout :daily_report, after: {3, :days}, action: :generate_report, check_interval: "0 9 * * *"
  end
end
```

### What polling costs

The workflow-level `check_interval` applies to **automatic step triggers as
well as timeouts**, and every trigger gets its own scheduler. That means the
cost multiplies with the size of the workflow, not with the number of records:

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
> For sub-minute precision, use a more frequent cron expression like `"* * * * * *"` (every second, if your Oban configuration supports it) — but see [What polling costs](#what-polling-costs) first, and set it on the individual timeout rather than the whole workflow.

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
