defmodule AshWorkflow.Transformers.AddObanTriggers do
  @moduledoc """
  Generates ash_oban triggers for automatic workflow steps.

  For each automatic (non-manual, non-terminal) step, adds an Oban trigger that:

  - Matches records where `state == :step_name`
  - Calls the step's action (which has `transition_state` injected by `AddActions`)
  - Uses explicit `worker_module_name` and `scheduler_module_name` to prevent
    dangling jobs if steps are renamed
  - Streams with `:full_read` since the `where` clause depends on mutable state

  Module names follow the pattern:
  - Worker: `{Resource}.AshWorkflow.Workers.{StepName}`
  - Scheduler: `{Resource}.AshWorkflow.Schedulers.{StepName}`
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

    {:ok, dsl}
  end

  defp add_step_trigger(dsl, resource, step) do
    step_name = step.name
    worker_module = Module.concat([resource, AshWorkflow, Workers, Macro.camelize(Atom.to_string(step_name))])
    scheduler_module = Module.concat([resource, AshWorkflow, Schedulers, Macro.camelize(Atom.to_string(step_name))])

    trigger =
      Transformer.build_entity!(AshOban, [:oban, :triggers], :trigger,
        name: step_name,
        action: step.action,
        where: Ash.Expr.expr(state == ^step_name),
        worker_module_name: worker_module,
        scheduler_module_name: scheduler_module,
        stream_with: :full_read
      )

    Transformer.add_entity(dsl, [:oban, :triggers], trigger)
  end

  def before?(AshOban.Transformers.SetDefaults), do: true
  def before?(AshOban.Transformers.DefineSchedulers), do: true
  def before?(AshOban.Transformers.DefineActionWorkers), do: true
  def before?(_), do: false
end
