# AshWorkflow Timeout Patterns

## How Timeouts Work

Timeouts in AshWorkflow are powered by Oban cron jobs. When a step has timeouts, AshWorkflow generates an Oban trigger that periodically checks whether the `state_entered_at` timestamp has exceeded the configured duration.

The check happens on the schedule defined by `check_interval` (default: every minute). This means timeouts are not precise to the second — they fire on the next cron tick after the deadline has passed.

Set `check_interval` on the `workflow` block to change it for every trigger on the resource, or on an individual `timeout` to override that default:

```elixir
workflow do
  check_interval "0 * * * *"

  step :awaiting_review do
    transition :approve, to: :approved

    timeout :nudge, after: {2, :days}, action: :send_nudge
    timeout :urgent, after: {30, :minutes}, transition_to: :escalated, check_interval: "* * * * *"
  end
end
```

Polling is not free, and its cost scales with the number of triggers on the resource rather than the number of records: each automatic step and each timeout gets its own scheduler, and each runs a filtered query on every tick whether or not anything is waiting. Eight triggers at the default interval is 480 queries an hour. Match the interval to the precision the deadline needs — for day-scale workflows, hourly behaves identically to users.

## Action Timeouts vs Transition Timeouts

### Action Timeouts

Run a side-effect without changing state. The workflow remains in the current step.

```elixir
timeout :reminder, after: {3, :days}, action: :send_reminder
```

Use for:
- Sending reminder emails or notifications
- Logging warnings
- Triggering external alerts

The referenced action must be defined as an update action on the resource:

```elixir
actions do
  update :send_reminder do
    accept []
    # your reminder logic
  end
end
```

### Transition Timeouts

Force the workflow to a different state after a deadline.

```elixir
timeout :expire, after: {14, :days}, transition_to: :expired
```

Use for:
- Offer expirations
- SLA enforcement
- Automatic escalation to a different review queue

Transition timeouts generate a hidden `__timeout_<name>` action — you do not need to define anything.

## Repeating Timeouts

Set `repeat: true` to fire a timeout repeatedly on the same interval:

```elixir
timeout :follow_up, after: {3, :days}, action: :send_follow_up, repeat: true
```

Without `repeat`, an action timeout fires once after the deadline and then stops. With `repeat`, it fires every interval (e.g., every 3 days) as long as the workflow remains in that step.

Transition timeouts ignore `repeat` — once the state changes, the timeout is no longer relevant.

## Combining Multiple Timeouts

A single step can have multiple timeouts with different deadlines:

```elixir
step :awaiting_response do
  transition :accept, to: :accepted
  transition :decline, to: :declined

  timeout :gentle_reminder, after: {2, :days}, action: :send_gentle_reminder
  timeout :urgent_reminder, after: {5, :days}, action: :send_urgent_reminder
  timeout :expire, after: {14, :days}, transition_to: :expired
end
```

This creates three independent Oban triggers, each with its own check schedule.

## Tuning Check Intervals

By default, timeouts are checked every minute (`"* * * * *"`). For less time-sensitive deadlines, reduce the frequency:

```elixir
# Check every hour — suitable for multi-day deadlines
timeout :stale_check, after: {30, :days}, action: :notify_stale, check_interval: "0 * * * *"

# Check every 15 minutes
timeout :escalation, after: {4, :hours}, transition_to: :escalated, check_interval: "*/15 * * * *"
```

Reducing check frequency lowers database load from Oban polling queries.

## Duration Units

Supported units for the `after` tuple:

| Unit | Example |
|---|---|
| `:seconds` | `{30, :seconds}` |
| `:minutes` | `{15, :minutes}` |
| `:hours` | `{4, :hours}` |
| `:days` | `{7, :days}` |

The value must be a positive integer.

## Common Mistakes

### Using both `action` and `transition_to`

```elixir
# Bad — compile error
timeout :reminder, after: {3, :days}, action: :send_reminder, transition_to: :escalated
```

A timeout must do exactly one thing: run an action OR transition state.

If you need both (send a notification AND change state), use two timeouts at the same deadline:

```elixir
timeout :escalation_notice, after: {7, :days}, action: :send_escalation_notice
timeout :escalation, after: {7, :days}, transition_to: :escalated
```

### Forgetting to define the timeout action

```elixir
# The timeout references :send_reminder — you must define it
timeout :reminder, after: {3, :days}, action: :send_reminder

actions do
  update :send_reminder do
    accept []
  end
end
```

## Measuring against a different field

By default a timeout measures its `after` duration from `state_entered_at` — how
long the workflow has been sitting in the current step. The `field` option
measures against any datetime attribute or calculation on the resource instead,
which is what you want for data-driven deadlines:

```elixir
# "3 months since their last session", not "3 months in this state"
timeout :dormant, after: {90, :days}, field: :last_session_date, transition_to: :dormant
```

The field must exist and must be a datetime type — both are checked at compile
time.

### `repeat: true` is rejected with a custom `field`

Repeating timeouts work by resetting `state_entered_at` after each firing. With a
custom field, that would mean writing "now" to a field representing a real-world
event that did not happen — so the combination is a compile-time error rather
than silently-wrong data.

For periodic checks against a custom field, use a non-repeating timeout with a
short `check_interval`; it keeps matching on every poll while the condition
holds.

```elixir
timeout :dormant_check,
  after: {90, :days},
  field: :last_session_date,
  action: :flag_dormant,
  check_interval: "0 9 * * *"
```
