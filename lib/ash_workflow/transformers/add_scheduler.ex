defmodule AshWorkflow.Transformers.AddScheduler do
  @moduledoc """
  Describes the workflow's scheduled work, then hands it to the selected
  scheduler.

  Every automatic step and every timeout becomes one
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

  alias AshWorkflow.Entities.Step
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

    works = step_works(steps, resource) ++ timeout_works(steps, resource)

    # Persisted for every scheduler, not just the selected one, so that a
    # runtime implementation can read back what the workflow declared without
    # re-deriving it from steps and timeouts. `AshWorkflow.Info.scheduled_work/1`
    # is the reader.
    dsl = Transformer.persist(dsl, :ash_workflow_scheduled_work, works)

    scheduler.transform(dsl, works, opts)
  end

  defp step_works(steps, resource) do
    steps
    |> Enum.reject(&(Step.manual?(&1) || &1.terminal))
    |> Enum.map(fn step ->
      step_name = step.name

      %Work{
        name: step_name,
        kind: :step,
        resource: resource,
        step: step_name,
        action: step.action,
        on_error: on_error(step),
        match: Ash.Expr.expr(state == ^step_name),
        deadline: nil
      }
    end)
  end

  defp on_error(%{on_error: nil}), do: nil
  defp on_error(step), do: AddActions.on_error_action_name(step)

  defp timeout_works(steps, resource) do
    steps
    |> Enum.reject(& &1.terminal)
    |> Enum.flat_map(fn step -> Enum.map(step.timeouts, &timeout_work(step, &1, resource)) end)
  end

  defp timeout_work(step, timeout, resource) do
    step_name = step.name
    {duration_value, duration_unit} = timeout.after
    ago_unit = singular_unit(duration_unit)
    field = timeout.field

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
      match:
        Ash.Expr.expr(state == ^step_name and ^ref(field) <= ago(^duration_value, ^ago_unit)),
      deadline: %{field: field, after: timeout.after},
      repeat?: timeout.repeat,
      # An action timeout does not change state, so nothing stops it matching
      # again on the next poll. A transition timeout leaves the step it matched
      # on, which is a durable record that it fired.
      once?: not timeout.repeat and timeout.action != nil,
      self_scheduled?: timeout.self_scheduled?,
      opts: [check_interval: timeout.check_interval]
    }
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
