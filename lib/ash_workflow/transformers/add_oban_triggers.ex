defmodule AshWorkflow.Transformers.AddObanTriggers do
  @moduledoc """
  Generates ash_oban triggers for automatic workflow steps and timeouts.

  ## Automatic step triggers

  For each automatic (non-manual, non-terminal) step, adds an Oban trigger that:

  - Matches records where `state == :step_name`
  - Calls the step's action (which has `transition_state` injected by `AddActions`)
  - Uses explicit `worker_module_name` and `scheduler_module_name` to prevent
    dangling jobs if steps are renamed
  - Streams with `:full_read` since the `where` clause depends on mutable state

  ## Timeout triggers

  For each timeout on any step, adds an Oban trigger that:

  - Matches records where `state == :step_name` AND `state_entered_at <= ago(duration)`
  - For action timeouts: calls the user-defined action (does not change state)
  - For transition timeouts: calls the generated `__timeout_<name>` action
  - Uses a configurable `scheduler_cron` (default: every minute) to poll
  - Streams with `:full_read` since the where clause depends on time

  Module names follow the pattern:
  - Worker: `{Resource}.AshWorkflow.Workers.{StepName}` or `...Timeouts.{TimeoutName}`
  - Scheduler: `{Resource}.AshWorkflow.Schedulers.{StepName}` or `...Timeouts.{TimeoutName}`
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  require Ash.Expr

  def transform(dsl) do
    steps = Transformer.get_entities(dsl, [:workflow])
    resource = Transformer.get_persisted(dsl, :module)

    dsl =
      steps
      |> Enum.reject(&(&1.manual || &1.terminal))
      |> Enum.reduce(dsl, fn step, dsl ->
        add_step_trigger(dsl, resource, step)
      end)

    dsl =
      steps
      |> Enum.reject(& &1.terminal)
      |> Enum.flat_map(fn step -> Enum.map(step.timeouts, &{step, &1}) end)
      |> Enum.reduce(dsl, fn {step, timeout}, dsl ->
        add_timeout_trigger(dsl, resource, step, timeout)
      end)

    {:ok, dsl}
  end

  defp add_step_trigger(dsl, resource, step) do
    step_name = step.name

    worker_module =
      Module.concat([resource, AshWorkflow, Workers, Macro.camelize(Atom.to_string(step_name))])

    scheduler_module =
      Module.concat([
        resource,
        AshWorkflow,
        Schedulers,
        Macro.camelize(Atom.to_string(step_name))
      ])

    trigger =
      Transformer.build_entity!(AshOban, [:oban, :triggers], :trigger,
        name: step_name,
        action: step.action,
        where: Ash.Expr.expr(state == ^step_name),
        queue: :workflow,
        worker_module_name: worker_module,
        scheduler_module_name: scheduler_module,
        stream_with: :full_read
      )

    Transformer.add_entity(dsl, [:oban, :triggers], trigger)
  end

  defp add_timeout_trigger(dsl, resource, step, timeout) do
    step_name = step.name
    timeout_name = timeout.name
    {duration_value, duration_unit} = timeout.after
    ago_unit = singular_unit(duration_unit)

    action =
      if timeout.transition_to do
        :"__timeout_#{timeout_name}"
      else
        timeout.action
      end

    label = Macro.camelize(Atom.to_string(timeout_name))
    worker_module = Module.concat([resource, AshWorkflow, Workers, Timeouts, label])
    scheduler_module = Module.concat([resource, AshWorkflow, Schedulers, Timeouts, label])

    trigger =
      Transformer.build_entity!(AshOban, [:oban, :triggers], :trigger,
        name: :"__timeout_trigger_#{timeout_name}",
        action: action,
        where:
          Ash.Expr.expr(
            state == ^step_name and state_entered_at <= ago(^duration_value, ^ago_unit)
          ),
        queue: :workflow,
        worker_module_name: worker_module,
        scheduler_module_name: scheduler_module,
        scheduler_cron: timeout.check_interval,
        stream_with: :full_read
      )

    Transformer.add_entity(dsl, [:oban, :triggers], trigger)
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
