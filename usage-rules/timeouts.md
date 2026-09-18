# AshWorkflow Timeout Patterns

## How Timeouts Work

Timeouts in AshWorkflow are powered by Oban cron jobs. When a step has timeouts, AshWorkflow generates an Oban trigger that periodically checks whether the `state_entered_at` timestamp has exceeded the configured duration.

The check happens on the schedule defined by `check_interval` (default: every minute). This means timeouts are not precise to the second — they fire on the next cron tick after the deadline has passed.

One minute is the shortest deadline you can ask for. Cron cannot poll more often than once a minute, so a sub-minute `fire_after` would fire up to 60 seconds late — an error larger than the deadline itself. `fire_after: {30, :seconds}` is a compile error. Set `self_scheduled?: true` if something other than cron drives the trigger at the resolution the deadline needs.

Set `check_interval` on the `workflow` block to change it for every trigger on the resource, or on an individual `timeout` to override that default:

```elixir
workflow do
  check_interval "0 * * * *"

  step :awaiting_review do
    transition :approve, to: :approved

    timeout :nudge, fire_after: {2, :days}, action: :send_nudge

    timeout :urgent do
      fire_after {30, :minutes}
      transition_to :escalated
      check_interval "* * * * *"
    end
  end
end
```

Polling is not free, and its cost scales with the number of triggers on the resource rather than the number of records: each automatic step and each timeout gets its own scheduler, and each runs a filtered query on every tick whether or not anything is waiting. Eight triggers at the default interval is 480 queries an hour. Match the interval to the precision the deadline needs — for day-scale workflows, hourly behaves identically to users.

## Inspecting What Is Scheduled

`pending_deadlines` lists the timeouts ahead of a record in its current step, soonest first:

```elixir
record = Ash.load!(record, :pending_deadlines)

record.pending_deadlines
#=> [
#=>   %{name: :nudge, due_at: ~U[2026-09-03 10:00:00Z], kind: :action, target: nil},
#=>   %{name: :escalation, due_at: ~U[2026-09-08 10:00:00Z], kind: :transition, target: :escalated}
#=> ]
```

Nothing is stored — each `due_at` is `field + fire_after`, computed on read. That makes it a forward-looking companion to the transition log's backward-looking history, with no extra table and nothing that can drift out of sync.

Read a `due_at` in the past as "was due", not "will fire". A transition timeout leaves the list once it fires, because firing changes the state. A non-repeating action timeout does not change state, so its deadline stays derivable after it has fired and will still be listed.

## Indexing

Each poll filters on `state`, and each timeout also filters on its `field`. `ago/2` compiles to a bind parameter rather than a per-row function call, so a timeout's query reaches Postgres as `state = $1 AND state_entered_at <= $2` — an ordinary composite range scan. With an index on `(state, state_entered_at)` a poll that finds nothing costs almost nothing; without one it is a sequential scan of the table, on every tick, for every trigger.

On `AshPostgres.DataLayer` these indexes are added for you, one per distinct timeout `field`, plus `(state)` alone for workflows with no timeouts. A `custom_indexes` entry you declare on the same fields takes precedence, and `generate_indexes? false` on the `workflow` block turns the generation off entirely:

```elixir
workflow do
  generate_indexes? false
  # ...
end
```

On other data layers, `AshWorkflow.Info.recommended_indexes/1` returns the same list so you can create them yourself.

Timeout fields backed by calculations are not indexed, since they are not columns. Prefer a plain attribute for a timeout `field` on a large table.

## Action Timeouts vs Transition Timeouts

### Action Timeouts

Run a side-effect without changing state. The workflow remains in the current step.

```elixir
timeout :reminder, fire_after: {3, :days}, action: :send_reminder
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
timeout :expire, fire_after: {14, :days}, transition_to: :expired
```

Use for:
- Offer expirations
- SLA enforcement
- Automatic escalation to a different review queue

Transition timeouts generate a hidden `__timeout_<step>_<name>` action — you do not need to define anything. The name is scoped to the step, so two steps may each declare a timeout with the same name.

## Recurring Actions with `every`

Use `every`, a sibling entity to `timeout` declared inside the same `step` block, to fire an action repeatedly on an interval:

```elixir
every :follow_up do
  interval {3, :days}
  action :send_follow_up
end
```

An action timeout fires once after the deadline and then stops. `every` fires every interval (e.g., every 3 days) as long as the workflow remains in that step. `every` always requires `action` and has no `transition_to`, since firing never leaves the step — a repeating action that also left the step would never come round to repeat.

## Combining Multiple Timeouts

A single step can have multiple timeouts with different deadlines:

```elixir
step :awaiting_response do
  transition :accept, to: :accepted
  transition :decline, to: :declined

  timeout :gentle_reminder, fire_after: {2, :days}, action: :send_gentle_reminder
  timeout :urgent_reminder, fire_after: {5, :days}, action: :send_urgent_reminder
  timeout :expire, fire_after: {14, :days}, transition_to: :expired
end
```

This creates three independent Oban triggers, each with its own check schedule.

## Tuning Check Intervals

By default, timeouts are checked every minute (`"* * * * *"`). For less time-sensitive deadlines, reduce the frequency:

```elixir
# Check every hour — suitable for multi-day deadlines
timeout :stale_check do
  fire_after {30, :days}
  action :notify_stale
  check_interval "0 * * * *"
end

# Check every 15 minutes
timeout :escalation do
  fire_after {4, :hours}
  transition_to :escalated
  check_interval "*/15 * * * *"
end
```

Reducing check frequency lowers database load from Oban polling queries.

## Retry

A timeout can declare its own `retry` block, with the same `max_attempts` and `backoff` options a step's can have:

```elixir
timeout :reminder do
  fire_after {3, :days}
  action :send_reminder

  retry do
    max_attempts 3
    backoff {10, :seconds}
  end
end
```

`max_attempts` defaults to `1`, so a timeout with no `retry` block runs its action once and does not retry. `backoff` defaults to `:exponential` and has no effect while `max_attempts` is `1`.

## Duration Units

Supported units for the `fire_after` tuple:

| Unit | Example |
|---|---|
| `:seconds` | `{90, :seconds}` |
| `:minutes` | `{15, :minutes}` |
| `:hours` | `{4, :hours}` |
| `:days` | `{7, :days}` |

The value must be a positive integer.

## Common Mistakes

### Using both `action` and `transition_to`

```elixir
# Bad — compile error
timeout :reminder, fire_after: {3, :days}, action: :send_reminder, transition_to: :escalated
```

A timeout must do exactly one thing: run an action OR transition state.

If you need both (send a notification AND change state), use two timeouts at the same deadline:

```elixir
timeout :escalation_notice, fire_after: {7, :days}, action: :send_escalation_notice
timeout :escalation, fire_after: {7, :days}, transition_to: :escalated
```

### Asking for a sub-minute deadline

```elixir
# Bad — compile error, cron cannot poll this often
timeout :quick_check, fire_after: {30, :seconds}, action: :check_status
```

Either lengthen the deadline to at least `{1, :minutes}`, or declare that you drive the trigger yourself:

```elixir
timeout :quick_check do
  fire_after {30, :seconds}
  action :check_status
  self_scheduled? true
end
```

`self_scheduled?: true` changes nothing about what is generated — the scheduler and its cron still exist, so `AshOban.schedule/2` and `AshOban.schedule_and_run_triggers/1` keep working. It records that something calls them more often than the cron does, and permits the shorter duration. `demos/ats` is the worked example: a GenServer ticks every second and invokes the trigger, which is what makes its 30-second deadline honourable.

This also applies when a custom `field` carries the deadline. `{1, :minutes}` and `{1, :seconds}` both mean "once that instant has passed" — the polling interval, not the duration, decides how soon after — so use `{1, :minutes}`.

### Forgetting to define the timeout action

```elixir
# The timeout references :send_reminder — you must define it
timeout :reminder, fire_after: {3, :days}, action: :send_reminder

actions do
  update :send_reminder do
    accept []
  end
end
```

## Measuring against a different field

By default a timeout measures its `fire_after` duration from `state_entered_at` — how
long the workflow has been sitting in the current step. The `field` option
measures against any datetime attribute or calculation on the resource instead,
which is what you want for data-driven deadlines:

```elixir
# "3 months since their last session", not "3 months in this state"
timeout :dormant do
  fire_after {90, :days}
  field :last_session_date
  transition_to :dormant
end
```

The field must exist and must be a datetime type — both are checked at compile
time.

### `every` has no `field` option

`every` works by resetting `state_entered_at` after each firing. With a
custom field, that would mean writing "now" to a field representing a real-world
event that did not happen — so `every` always measures against
`state_entered_at` and offers no `field` option at all.

For periodic checks against a custom field, use a timeout with a short
`check_interval`; it keeps matching on every poll while the condition holds.

```elixir
timeout :dormant_check do
  fire_after {90, :days}
  field :last_session_date
  action :flag_dormant
  check_interval "0 9 * * *"
end
```
