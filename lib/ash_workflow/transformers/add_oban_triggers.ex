defmodule AshWorkflow.Transformers.AddObanTriggers do
  @moduledoc """
  Generates ash_oban triggers for automatic workflow steps and timeouts.

  ## Automatic step triggers

  For each automatic (non-manual, non-terminal) step, adds an Oban trigger that:

  - Matches records where `state == :step_name`
  - Calls the step's action (which has `transition_state` injected by `AddActions`)
  - Uses explicit `worker_module_name` and `scheduler_module_name` to prevent
    dangling jobs if steps are renamed
  - Streams with `:keyset` (see "Streaming" below)

  ## Timeout triggers

  For each timeout on any step, adds an Oban trigger that:

  - Matches records where `state == :step_name` AND `<field> <= ago(duration)`,
    where `<field>` defaults to `state_entered_at` but can be overridden per timeout
  - For action timeouts: calls the user-defined action (does not change state)
  - For transition timeouts: calls the generated `__timeout_<step>_<name>` action
  - Uses the timeout's own `check_interval` if set, otherwise the workflow-level
    `check_interval` (default: every minute), to poll
  - Streams with `:keyset` (see "Streaming" below)

  Module names follow the pattern:
  - Worker: `{Resource}.AshWorkflow.Workers.{StepName}` or `...Timeouts.{TimeoutName}`
  - Scheduler: `{Resource}.AshWorkflow.Schedulers.{StepName}` or `...Timeouts.{TimeoutName}`

  ## Streaming

  Triggers stream with `:keyset`. ash_oban suggests `:full_read` when a `where`
  clause changes between batches, which ours do — both `state == :step` (records
  leave as they are processed) and `field <= ago(...)` (records enter as time
  passes). Keyset is still the right choice here because it orders by primary
  key, which never changes: unlike `:offset`, a row leaving the filter mid-stream
  cannot shift another row past the cursor. The only effect is that a record
  becoming eligible mid-stream, at a key the stream has already passed, waits for
  the next poll — bounded by `check_interval`, and irrelevant at the timescale
  timeouts operate on.

  What `:full_read` costs in exchange is memory: it loads every matching record
  in one unpaginated read, so a backlog after downtime is read into memory all at
  once. Keyset bounds that.

  ## Indexing

  The generated `where` clauses are index-friendly, which is easy to miss:
  `ago/2` compiles to a bind parameter, not a function call over each row, so a
  timeout's filter reaches Postgres as `state = $1 AND state_entered_at <= $2`.
  A composite index on `(state, state_entered_at)` therefore serves every
  automatic-step trigger and every default-field timeout. See
  `AshWorkflow.Info.recommended_indexes/1`.
  """
  use Spark.Dsl.Transformer

  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Transformers.AddActions
  alias Spark.Dsl.Transformer
  import Ash.Expr, only: [ref: 1]
  require Ash.Expr

  def transform(dsl) do
    steps =
      dsl
      |> Transformer.get_entities([:workflow])
      |> Enum.filter(&match?(%Step{}, &1))

    resource = Transformer.get_persisted(dsl, :module)

    defaults = [
      queue: Transformer.get_option(dsl, [:workflow], :queue),
      check_interval: Transformer.get_option(dsl, [:workflow], :check_interval)
    ]

    dsl =
      steps
      |> Enum.reject(&(Step.manual?(&1) || &1.terminal))
      |> Enum.reduce(dsl, fn step, dsl ->
        add_step_trigger(dsl, resource, step, defaults)
      end)

    dsl =
      steps
      |> Enum.reject(& &1.terminal)
      |> Enum.flat_map(fn step -> Enum.map(step.timeouts, &{step, &1}) end)
      |> Enum.reduce(dsl, fn {step, timeout}, dsl ->
        add_timeout_trigger(dsl, resource, step, timeout, defaults)
      end)

    {:ok, dsl}
  end

  defp add_step_trigger(dsl, resource, step, defaults) do
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
        queue: defaults[:queue],
        worker_module_name: worker_module,
        scheduler_module_name: scheduler_module,
        scheduler_cron: defaults[:check_interval],
        stream_with: :keyset
      )
      |> maybe_put_on_error(step)

    Transformer.add_entity(dsl, [:oban, :triggers], trigger)
  end

  defp maybe_put_on_error(trigger, %{on_error: nil}), do: trigger

  defp maybe_put_on_error(trigger, step) do
    %{trigger | on_error: AddActions.on_error_action_name(step)}
  end

  defp add_timeout_trigger(dsl, resource, step, timeout, defaults) do
    step_name = step.name
    timeout_name = timeout.name
    {duration_value, duration_unit} = timeout.after
    ago_unit = singular_unit(duration_unit)
    field = timeout.field

    action =
      if timeout.transition_to do
        AddActions.timeout_action_name(step, timeout)
      else
        timeout.action
      end

    # Scoped by step so two steps can declare a timeout with the same name.
    step_label = Macro.camelize(Atom.to_string(step_name))
    label = Macro.camelize(Atom.to_string(timeout_name))
    worker_module = Module.concat([resource, AshWorkflow, Workers, Timeouts, step_label, label])

    scheduler_module =
      Module.concat([resource, AshWorkflow, Schedulers, Timeouts, step_label, label])

    # For action timeouts (no state change), trigger_once? prevents re-firing
    # unless repeat: true is set. Transition timeouts naturally fire once since
    # the state changes, so trigger_once? is not needed.
    trigger_once? = not timeout.repeat and timeout.action != nil

    trigger =
      Transformer.build_entity!(AshOban, [:oban, :triggers], :trigger,
        name: :"__timeout_trigger_#{step_name}_#{timeout_name}",
        action: action,
        where:
          Ash.Expr.expr(state == ^step_name and ^ref(field) <= ago(^duration_value, ^ago_unit)),
        queue: defaults[:queue],
        trigger_once?: trigger_once?,
        worker_module_name: worker_module,
        scheduler_module_name: scheduler_module,
        # nil means the timeout did not override the workflow-level setting.
        scheduler_cron: timeout.check_interval || defaults[:check_interval],
        stream_with: :keyset
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
