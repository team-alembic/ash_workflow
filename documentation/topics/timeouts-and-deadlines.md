# Timeouts and Deadlines

Timeouts let you react to a workflow being stuck in a state. They're useful for reminders, escalations, SLA enforcement, and offer expirations.

## How timeouts work

Each timeout becomes an Oban trigger that polls on a cron schedule (default: every minute). The trigger's `where` clause checks both the state and the `state_entered_at` timestamp:

```
where: state == :step_name and state_entered_at <= ago(duration)
```

Once the condition is met, the trigger fires the timeout's action. When the workflow leaves the state (via a manual transition or another timeout), the `where` clause stops matching and the trigger naturally stops firing.

## Action timeouts

Action timeouts run an Ash action without changing state. Use them for reminders, notifications, or logging:

```elixir
step :awaiting_response do
  manual true
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
  manual true
  transition :approve, to: :approved

  timeout :escalation, after: {7, :days}, transition_to: :escalated
end

step :escalated, terminal: true
```

The extension generates a hidden update action (`:__timeout_escalation`) that performs the state transition. You don't need to define this action yourself.

## Repeating timeouts

By default, action timeouts fire once. Set `repeat: true` to keep firing on every scheduler cycle while the workflow remains in that state:

```elixir
step :awaiting_response do
  manual true
  transition :respond, to: :next_step

  # Fires once after 3 days
  timeout :reminder, after: {3, :days}, action: :send_reminder

  # Fires after 3 days, then on every check_interval while still waiting
  timeout :follow_up, after: {3, :days}, action: :send_follow_up, repeat: true
end
```

When a repeating timeout fires, the extension resets `state_entered_at` to the current time. This restarts the duration window — so `after: {3, :days}` means the action fires every 3 days, not every scheduler cycle.

Non-repeating timeouts (the default) use Oban's `trigger_once?` to prevent re-firing after the action completes. Transition timeouts (with `transition_to`) don't need either mechanism since the state change naturally prevents re-firing.

## Duration units

Supported units: `:seconds`, `:minutes`, `:hours`, `:days`.

```elixir
timeout :quick_check, after: {30, :seconds}, action: :check_status
timeout :hourly_ping, after: {1, :hours}, action: :send_ping
timeout :weekly_expire, after: {7, :days}, transition_to: :expired
```

## Polling interval

By default, timeout triggers check every minute (`"* * * * *"`). You can configure this per-timeout with `check_interval`:

```elixir
# Check once a day at 9am instead of every minute
timeout :daily_report, after: {3, :days}, action: :generate_report, check_interval: "0 9 * * *"
```

## Oban queue configuration

By default, all workflow triggers use the `:workflow` queue. You can override this at the workflow level:

```elixir
workflow do
  queue :hiring_pipeline

  step :process, action: :run_processing, on_success: :review
  # ...
end
```

All generated triggers (automatic steps and timeouts) will use the specified queue. Ensure it's configured in your Oban setup:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10, hiring_pipeline: 5]
```

## The `state_entered_at` attribute

The extension auto-adds a `state_entered_at` (`utc_datetime_usec`) attribute to the resource. It's updated every time the state changes — on `:start`, on manual transitions, and on automatic step completions. Timeout durations are calculated from this timestamp.

If you need to define this attribute yourself (e.g., with a custom default or source), the extension skips adding it.
