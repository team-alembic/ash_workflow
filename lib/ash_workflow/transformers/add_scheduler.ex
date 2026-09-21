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

    %Work{
      # Scoped by step so two steps can declare a timeout with the same name.
      name: :"__timeout_trigger_#{step_name}_#{timeout.name}",
      kind: :timeout,
      resource: resource,
      step: step_name,
      timeout: timeout.name,
      action: action,
      match: Ash.Expr.expr(^in_step(state_attribute, step_name) and ^due(timeout, field)),
      deadline: %{field: field, fire_after: timeout.fire_after},
      repeat?: false,
      # A timeout never repeats: an action timeout does not change state, so
      # `once?` stops it matching again on the next poll. A transition timeout
      # leaves the step it matched on, which is itself a durable record that
      # it fired.
      once?: timeout.action != nil,
      self_scheduled?: timeout.self_scheduled?,
      retry: timeout.retry || %Retry{},
      opts: [check_interval: timeout.check_interval]
    }
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
    {duration_value, duration_unit} = every.interval
    ago_unit = singular_unit(duration_unit)
    field = Every.last_fired_field(step_name, every)

    # A record whose column is still `nil` has never fired this `every`, and is
    # treated as due rather than waiting for a column that firing itself is what
    # would write. See `AshWorkflow.Entities.Every`.
    base_match =
      Ash.Expr.expr(
        ^in_step(state_attribute, step_name) and
          (is_nil(^ref(field)) or ^ref(field) <= ago(^duration_value, ^ago_unit))
      )

    %Work{
      # Scoped by step so two steps can declare an every with the same name.
      name: :"__every_trigger_#{step_name}_#{every.name}",
      kind: :timeout,
      resource: resource,
      step: step_name,
      timeout: every.name,
      action: every.action,
      match: until_match(base_match, every),
      deadline: %{field: field, fire_after: every.interval},
      repeat?: true,
      until: every.until,
      once?: false,
      self_scheduled?: every.self_scheduled?,
      retry: every.retry || %Retry{},
      opts: [check_interval: every.check_interval]
    }
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
