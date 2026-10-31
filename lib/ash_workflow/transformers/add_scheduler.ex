defmodule AshWorkflow.Transformers.AddScheduler do
  @moduledoc """
  Describes the workflow's scheduled work, then hands it to the selected
  scheduler.

  Every automatic step, every timeout and every `every` becomes one
  `AshWorkflow.Scheduler.Work`. The scheduler's `transform/3` then adds whatever
  it needs to the resource — `AshWorkflow.Scheduler.Oban` adds AshOban triggers,
  another implementation might add nothing at all.

  This transformer owns the translation from workflow vocabulary into `Work`,
  which is the whole reason a scheduler needs no understanding of steps,
  transitions or the state machine. It replaces
  `AshWorkflow.Transformers.AddObanTriggers`, which built triggers directly.

  ## `match` and `deadline`

  Each `Work` carries both, because the two sensible scheduling strategies read
  opposite ones. `match` selects records eligible now, for an implementation
  that polls. `deadline` is the rule for computing the exact instant, for an
  implementation that arms timers. For a timeout they describe the same fact:
  `match` is true exactly when `deadline` has passed.
  """
  use Spark.Dsl.Transformer

  alias AshWorkflow.Entities.Every
  alias AshWorkflow.Entities.Retry
  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Entities.Timeout
  alias AshWorkflow.Scheduler.Work
  alias AshWorkflow.Transformers.AddActions
  alias Spark.Dsl.Transformer

  import Ash.Expr, only: [ref: 1]
  require Ash.Expr

  def transform(dsl) do
    {scheduler, opts} = AshWorkflow.Info.scheduler(dsl)

    steps =
      dsl
      |> Transformer.get_entities([:workflow])
      |> Enum.filter(&match?(%Step{}, &1))

    resource = Transformer.get_persisted(dsl, :module)
    state_attribute = AshWorkflow.Info.state_attribute(dsl)

    works =
      step_works(steps, resource, state_attribute) ++
        every_works(steps, resource, state_attribute) ++
        timeout_works(steps, resource, state_attribute)

    # Persisted for every scheduler, not just the selected one, so that a
    # runtime implementation can read back what the workflow declared without
    # re-deriving it from steps and timeouts. `AshWorkflow.Info.scheduled_work/1`
    # is the reader.
    dsl = Transformer.persist(dsl, :ash_workflow_scheduled_work, works)

    scheduler.transform(dsl, works, opts)
  end

  defp step_works(steps, resource, state_attribute) do
    steps
    |> Enum.reject(&(Step.manual?(&1) || Step.terminal?(&1)))
    |> Enum.map(fn step ->
      step_name = step.name

      %Work{
        name: step_name,
        kind: :step,
        resource: resource,
        step: step_name,
        action: step.action,
        on_error: on_error(step),
        match: in_step(state_attribute, step_name),
        deadline: nil,
        retry: step.retry || %Retry{}
      }
    end)
  end

  defp on_error(%{on_error: nil}), do: nil
  defp on_error(step), do: AddActions.on_error_action_name(step)

  defp timeout_works(steps, resource, state_attribute) do
    steps
    |> Enum.reject(&Step.terminal?/1)
    |> Enum.flat_map(fn step ->
      Enum.map(step.timeouts, &timeout_work(step, &1, resource, state_attribute))
    end)
  end

  defp in_step(state_attribute, step_name) do
    Ash.Expr.expr(^ref(state_attribute) == ^step_name)
  end

  defp timeout_work(step, timeout, resource, state_attribute) do
    step_name = step.name
    field = Timeout.deadline_field(timeout)

    action =
      if timeout.transition_to do
        AddActions.timeout_action_name(step, timeout)
      else
        timeout.action
      end

    work = %Work{
      # Scoped by step so two steps can declare a timeout with the same name.
      name: :"__timeout_trigger_#{step_name}_#{timeout.name}",
      kind: :timeout,
      resource: resource,
      step: step_name,
      timeout: timeout.name,
      action: action,
      deadline: %{field: field, fire_after: timeout.fire_after},
      repeat?: false,
      # A transition timeout leaves the step it matched on, which is itself a
      # durable record that it fired. An action timeout stays, so it writes
      # this column instead.
      fired_field: Timeout.fired_field(step_name, timeout),
      self_scheduled?: timeout.self_scheduled?,
      retry: timeout.retry || %Retry{},
      opts: [check_interval: timeout.check_interval]
    }

    match =
      Ash.Expr.expr(
        ^in_step(state_attribute, step_name) and ^due(timeout, field) and ^Work.not_fired(work)
      )

    %{work | match: match}
  end

  defp every_works(steps, resource, state_attribute) do
    steps
    |> Enum.reject(&Step.terminal?/1)
    |> Enum.flat_map(fn step ->
      Enum.map(step.everys, &every_work(step, &1, resource, state_attribute))
    end)
  end

  defp every_work(step, every, resource, state_attribute) do
    step_name = step.name
    field = Every.last_fired_field(step_name, every)
    wall_clock = Every.wall_clock(every)

    base_match =
      Ash.Expr.expr(^in_step(state_attribute, step_name) and ^every_due(every, wall_clock, field))

    fires_field = Every.fires_field(step_name, every)

    match =
      base_match
      |> backoff_match(every, field, fires_field)
      |> max_fires_match(every, field, fires_field)
      |> until_match(every)

    %Work{
      # Scoped by step so two steps can declare an every with the same name.
      name: :"__every_trigger_#{step_name}_#{every.name}",
      kind: :timeout,
      resource: resource,
      step: step_name,
      timeout: every.name,
      action: every.action,
      match: match,
      deadline: every_deadline(field, every, wall_clock),
      repeat?: true,
      until: every.until,
      max_fires: every.max_fires,
      backoff: every.backoff,
      fires_field: fires_field,
      self_scheduled?: every.self_scheduled?,
      retry: every.retry || %Retry{},
      opts: [check_interval: every.check_interval]
    }
  end

  # An `every` declaring neither `interval` nor `at` is rejected by
  # `AshWorkflow.Verifiers.ValidateEvery`, but transformers run before
  # verifiers. Matching nothing here lets that verifier report the real error
  # instead of this function raising a FunctionClauseError first.
  defp every_due(%Every{interval: nil}, nil, _field), do: Ash.Expr.expr(false)

  # A record whose column is still `nil` has never fired this `every`, so the
  # interval is measured from `state_entered_at` instead: the first firing is
  # one whole interval after the record entered the step, not on entry. See
  # `AshWorkflow.Entities.Every`. Written as a disjunction rather than with a
  # coalescing function, which Ash's expression language does not have.
  defp every_due(%Every{interval: {value, unit}}, nil, field) do
    ago_unit = singular_unit(unit)

    Ash.Expr.expr(
      (is_nil(^ref(field)) and state_entered_at <= ago(^value, ^ago_unit)) or
        ^ref(field) <= ago(^value, ^ago_unit)
    )
  end

  # A wall-clock `every` is due when the most recent occurrence of its local
  # time is at or before now, and the last fire is older than that occurrence.
  # The zone comes out of the row, so the occurrence cannot be computed in
  # Elixir at query-build time the way every other deadline's bound is. The
  # data layer has to do the arithmetic per row.
  #
  # The subquery tries each of the last seven local dates. `on` is never empty,
  # so the most recent occurrence is one of them, and any older occurrence the
  # last fire predates means the most recent one is predated too. A missed
  # occurrence therefore fires late, once, on whichever day polling resumes,
  # the same as `AshWorkflow.WallClock.next_occurrence/3`.
  #
  # Postgres raises on a zone it does not recognise, which would fail the
  # whole trigger query rather than the one row. The `CASE` guard skips that
  # row instead, as `AshWorkflow.WallClock.next_occurrence/3` does, and `CASE`
  # is the one construct whose evaluation order Postgres guarantees.
  #
  # This is one `fragment` rather than a composition of Ash operators so that
  # nothing has to infer a type for a `time` or for an `AT TIME ZONE` result.
  # Everything that varies is a bound parameter, since `fragment` refuses an
  # interpolated string.
  #
  # `state_entered_at` and the last-fired column are stored as naive
  # timestamps holding UTC, so they are lifted to an instant with an explicit
  # `AT TIME ZONE 'UTC'` before being shifted into the row's own zone. Leaving
  # that implicit would resolve against the session's `TimeZone` setting.
  #
  # A stride compares the occurrence's local date with the last fire's, and
  # `date - date` is an integer count of days in Postgres. See
  # `AshWorkflow.WallClock` for why a duration comparison is not exact.
  #
  # `every ... at` therefore runs on a SQL data layer only.
  # `AshWorkflow.Scheduler.Precise` reads `Work.deadline` instead and computes
  # the same occurrence in Elixir through `AshWorkflow.WallClock`, so it needs
  # no data layer support at all.
  defp every_due(%Every{}, %AshWorkflow.WallClock{stride: nil} = wall_clock, field) do
    zone = time_zone_expr(wall_clock)

    Ash.Expr.expr(
      fragment(
        "CASE WHEN ? IN (SELECT name FROM pg_timezone_names) THEN EXISTS (SELECT 1 FROM (SELECT (now() AT TIME ZONE ?)::date - back AS day FROM generate_series(0, 6) AS back) AS o WHERE EXTRACT(ISODOW FROM o.day)::int = ANY(?) AND ((o.day + ?::time) AT TIME ZONE ?) <= now() AND (coalesce(?, ?) AT TIME ZONE 'UTC') < ((o.day + ?::time) AT TIME ZONE ?)) ELSE false END",
        ^zone,
        ^zone,
        ^days(wall_clock),
        ^time(wall_clock),
        ^zone,
        ^ref(field),
        ^ref(:state_entered_at),
        ^time(wall_clock),
        ^zone
      )
    )
  end

  defp every_due(%Every{}, %AshWorkflow.WallClock{stride: stride} = wall_clock, field) do
    zone = time_zone_expr(wall_clock)

    Ash.Expr.expr(
      fragment(
        "CASE WHEN ? IN (SELECT name FROM pg_timezone_names) THEN EXISTS (SELECT 1 FROM (SELECT (now() AT TIME ZONE ?)::date - back AS day FROM generate_series(0, 6) AS back) AS o WHERE EXTRACT(ISODOW FROM o.day)::int = ANY(?) AND ((o.day + ?::time) AT TIME ZONE ?) <= now() AND (coalesce(?, ?) AT TIME ZONE 'UTC') < ((o.day + ?::time) AT TIME ZONE ?) AND o.day - ((coalesce(?, ?) AT TIME ZONE 'UTC') AT TIME ZONE ?)::date >= ?) ELSE false END",
        ^zone,
        ^zone,
        ^days(wall_clock),
        ^time(wall_clock),
        ^zone,
        ^ref(field),
        ^ref(:state_entered_at),
        ^time(wall_clock),
        ^zone,
        ^ref(field),
        ^ref(:state_entered_at),
        ^zone,
        ^Ash.Expr.expr(type(^stride, :integer))
      )
    )
  end

  defp time(wall_clock), do: Ash.Expr.expr(type(^wall_clock.time, :time))
  defp days(wall_clock), do: Ash.Expr.expr(type(^wall_clock.days, {:array, :integer}))

  defp time_zone_expr(%AshWorkflow.WallClock{time_zone: zone}) when is_binary(zone), do: zone
  defp time_zone_expr(%AshWorkflow.WallClock{time_zone: attribute}), do: ref(attribute)

  # A wall-clock `every` has no duration to add to its last fire, so it carries
  # the schedule itself. `AshWorkflow.Scheduler.due_at/2` resolves both shapes.
  defp every_deadline(field, %Every{interval: interval}, nil) do
    %{field: field, fire_after: interval}
  end

  defp every_deadline(field, %Every{}, %AshWorkflow.WallClock{} = wall_clock) do
    %{field: field, fire_after: nil, wall_clock: wall_clock}
  end

  # A `fire_after` timeout is due once its anchor is older than the duration. A
  # `fire_at` timeout names the deadline instant itself, so it is due once that
  # instant has passed, with no arithmetic.
  defp due(%Timeout{fire_after: nil}, field) do
    Ash.Expr.expr(^ref(field) <= now())
  end

  defp due(%Timeout{fire_after: {value, unit}}, field) do
    ago_unit = singular_unit(unit)

    Ash.Expr.expr(^ref(field) <= ago(^value, ^ago_unit))
  end

  # The fire count belongs to the current step visit only. A last fire from
  # before `state_entered_at` was in an earlier visit, so it counts as none.
  defp fired_this_visit(field) do
    Ash.Expr.expr(not is_nil(^ref(field)) and ^ref(field) >= state_entered_at)
  end

  defp max_fires_match(match, %Every{max_fires: nil}, _field, _fires_field), do: match

  defp max_fires_match(match, %Every{max_fires: max_fires}, field, fires_field) do
    Ash.Expr.expr(^match and (not (^fired_this_visit(field)) or ^ref(fires_field) < ^max_fires))
  end

  # After `n` fires the gap is `interval` plus `Retry.delay_ms/2` for attempt
  # `n`. A fixed backoff makes that one constant, so it stays a bind parameter
  # against the `(state, field)` index. `:exponential` adds `n^4 + 15` seconds,
  # the formula `Retry.delay_ms/2` uses, which has to be computed per row.
  defp backoff_match(match, %Every{backoff: nil}, _field, _fires_field), do: match

  # Rejected by `AshWorkflow.Verifiers.ValidateEvery`, which runs after this
  # transformer.
  defp backoff_match(match, %Every{at: at}, _field, _fires_field) when not is_nil(at), do: match

  defp backoff_match(match, %Every{backoff: {_value, _unit} = backoff} = every, field, _fires) do
    gap_seconds =
      AshWorkflow.Duration.to_seconds(every.interval) + AshWorkflow.Duration.to_seconds(backoff)

    Ash.Expr.expr(
      ^match and (not (^fired_this_visit(field)) or ^ref(field) <= ago(^gap_seconds, :second))
    )
  end

  # AshSQL renders `datetime_add/3` as `datetime + amount * interval` without
  # parenthesising `amount`, so only the product goes in it. The constant part
  # of the gap moves to the other side as a bind parameter.
  defp backoff_match(match, %Every{backoff: :exponential} = every, field, fires_field) do
    constant_seconds = AshWorkflow.Duration.to_seconds(every.interval) + 15
    fires = ref(fires_field)

    Ash.Expr.expr(
      ^match and
        (not (^fired_this_visit(field)) or
           datetime_add(^ref(field), ^fires * ^fires * ^fires * ^fires, :second) <=
             ago(^constant_seconds, :second))
    )
  end

  # `until` is checked against `state_entered_at`, which an `every`'s own
  # firing no longer touches — see `AshWorkflow.Entities.Every`. Once that
  # instant is further in the past than the bound, this clause is false for
  # the rest of the step visit, so the record never matches again until it
  # leaves and re-enters. That is exactly "the firing stops".
  defp until_match(match, %Every{until: nil}), do: match

  defp until_match(match, %Every{until: {until_value, until_unit}}) do
    until_ago_unit = singular_unit(until_unit)

    Ash.Expr.expr(^match and ^ref(:state_entered_at) > ago(^until_value, ^until_ago_unit))
  end

  # ago/2 expects singular duration names (:day, :hour, :minute, :second)
  defp singular_unit(:days), do: :day
  defp singular_unit(:hours), do: :hour
  defp singular_unit(:minutes), do: :minute
  defp singular_unit(:seconds), do: :second

  def before?(AshOban.Transformers.SetDefaults), do: true
  def before?(AshOban.Transformers.DefineSchedulers), do: true
  def before?(AshOban.Transformers.DefineActionWorkers), do: true
  def before?(_), do: false
end
