defmodule AshWorkflow.Scheduler.Oban do
  @moduledoc """
  Runs a workflow's scheduled work through ash_oban. The default scheduler.

  Each `AshWorkflow.Scheduler.Work` becomes an `AshOban` trigger whose `where`
  is the work's `match` expression, so ash_oban discovers eligible records by
  polling rather than being told about deadlines. That makes the polling
  interval the floor on accuracy: cron cannot ask for less than a minute, which
  is why `AshWorkflow.Verifiers.ValidateTimeoutPrecision` rejects a shorter
  deadline.

  ## The resource must add the AshOban extension

  AshWorkflow does not add it. A workflow using a scheduler that has nothing to
  do with Oban should not carry the ash_oban DSL, so the extension goes where
  the choice is made:

      use Ash.Resource,
        domain: MyApp.Domain,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshWorkflow, AshOban]

  Omitting it while this scheduler is selected is a compile error naming the fix.

  ## Options

    * `:queue` — the Oban queue for every generated trigger. Defaults to the
      `workflow` block's `queue`.
    * `:check_interval` — the cron for every generated trigger. Defaults to the
      `workflow` block's `check_interval`. A timeout's own `check_interval`
      still overrides it.
    * `:actor` — the actor for every generated trigger, handed to ash_oban as
      the trigger's `default_actor`. The cron-fired scheduler reads eligible
      records as this actor, and the worker runs the step's or timeout's action
      as it when the job carries no actor of its own. Without it both run with
      a `nil` actor, so a resource whose read policy needs an actor never finds
      a record to run.

          scheduler {AshWorkflow.Scheduler.Oban,
                     actor: %MyApp.SystemActor{reason: "workflow"}}

  ## Entering an automatic step

  An automatic step has no deadline, so a record is due the moment it enters
  the step. `c:AshWorkflow.Scheduler.step_entered/2` queues that step's trigger
  with `AshOban.run_trigger/3` when the record enters it, so the action runs
  without waiting for the next `check_interval`. The worker re-checks the
  trigger's `where` before it runs, so a record that has already moved on is
  left alone.

  A step whose `on_success` or `on_error` routes the record back into the same
  step is not queued again. That route means "nothing to do yet", and the record waits for the
  next `check_interval`. A transition declared directly in the `state_machine`
  block, not in the `workflow`, does not run `AshWorkflow.Changes.RecordEvent`,
  so a record it moves into an automatic step also waits for the poll.

  The queued job carries no actor, the same as a job the cron poll queues.

  ## Retry

  A step's or timeout's `retry` block becomes the generated trigger's
  `max_attempts` and `backoff`. ash_oban runs the step's `on_error` action only
  after the final attempt has failed, which is the same rule
  `AshWorkflow.Scheduler.execute/3` documents.

  ## Pausing

  Every generated trigger's `where` also requires that
  `AshWorkflow.Scheduler.pause/1` does not hold the scheduler, read through the
  private `:ash_workflow_scheduler_paused?` calculation this scheduler adds to
  the resource. While paused, a poll queues nothing, and a job already queued
  finds its record no longer matching and cancels itself. The first poll after
  `AshWorkflow.Scheduler.resume/1` finds the work again.

  ## Module names

  Worker and scheduler module names are derived from the resource, the step and
  the timeout, and are set explicitly rather than left to ash_oban's defaults so
  that renaming a step does not leave jobs pointing at a module that no longer
  exists.
  """
  use AshWorkflow.Scheduler

  alias Ash.Resource.Builder
  alias AshWorkflow.Scheduler.Work
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  require Ash.Expr

  @impl AshWorkflow.Scheduler
  def transform(dsl, works, opts) do
    with :ok <- verify_extension(dsl),
         {:ok, dsl} <- add_paused_calculation(dsl, works) do
      {:ok, Enum.reduce(works, dsl, &add_trigger(&2, &1, opts))}
    end
  end

  defp add_paused_calculation(dsl, []), do: {:ok, dsl}

  defp add_paused_calculation(dsl, _works) do
    Builder.add_new_calculation(
      dsl,
      :ash_workflow_scheduler_paused?,
      :boolean,
      AshWorkflow.Calculations.SchedulerPaused,
      public?: false
    )
  end

  defp verify_extension(dsl) do
    if AshOban in Transformer.get_persisted(dsl, :extensions, []) do
      :ok
    else
      {:error,
       DslError.exception(
         path: [:workflow, :scheduler],
         message: """
         This workflow uses #{inspect(__MODULE__)}, which generates AshOban \
         triggers, but the resource does not have the AshOban extension.

         Add it alongside AshWorkflow:

             use Ash.Resource,
               domain: ...,
               extensions: [AshWorkflow, AshOban]

         AshWorkflow no longer adds AshOban for you, so that a workflow using a \
         scheduler unrelated to Oban does not carry the ash_oban DSL.
         """
       )}
    end
  end

  defp add_trigger(dsl, work, opts) do
    trigger =
      Transformer.build_entity!(AshOban, [:oban, :triggers], :trigger,
        name: work.name,
        action: work.action,
        where: Ash.Expr.expr(^work.match and not ash_workflow_scheduler_paused?),
        queue: queue(dsl, opts),
        on_error: work.on_error,
        max_attempts: work.retry.max_attempts,
        backoff: oban_backoff(work.retry.backoff),
        worker_module_name: module_name(work, Workers),
        scheduler_module_name: module_name(work, Schedulers),
        scheduler_cron: check_interval(dsl, work, opts),
        default_actor: opts[:actor],
        stream_with: :keyset
      )

    Transformer.add_entity(dsl, [:oban, :triggers], trigger)
  end

  @impl AshWorkflow.Scheduler
  def step_entered(record, works) do
    works
    |> Enum.filter(&(&1.kind == :step))
    |> Enum.each(&AshOban.run_trigger(record, &1.name))
  end

  # ash_oban's trigger `backoff` is in seconds, which is why a duration tuple
  # is converted here rather than handed through as-is.
  defp oban_backoff(:exponential), do: :exponential
  defp oban_backoff(duration), do: AshWorkflow.Duration.to_seconds(duration)

  defp queue(dsl, opts) do
    Keyword.get_lazy(opts, :queue, fn ->
      Transformer.get_option(dsl, [:workflow], :queue)
    end)
  end

  # A timeout may override the interval; a step may not, having no deadline of
  # its own to poll for.
  defp check_interval(dsl, %Work{kind: :timeout} = work, opts) do
    work.opts[:check_interval] || default_check_interval(dsl, opts)
  end

  defp check_interval(dsl, _work, opts), do: default_check_interval(dsl, opts)

  defp default_check_interval(dsl, opts) do
    Keyword.get_lazy(opts, :check_interval, fn ->
      Transformer.get_option(dsl, [:workflow], :check_interval)
    end)
  end

  # Preserved verbatim from the shape ash_oban triggers had before the
  # scheduler was pluggable: renaming these orphans enqueued jobs.
  defp module_name(%Work{kind: :step} = work, namespace) do
    Module.concat([work.resource, AshWorkflow, namespace, camelize(work.step)])
  end

  defp module_name(%Work{kind: :timeout} = work, namespace) do
    Module.concat([
      work.resource,
      AshWorkflow,
      namespace,
      Timeouts,
      camelize(work.step),
      camelize(work.timeout)
    ])
  end

  defp camelize(name), do: Macro.camelize(Atom.to_string(name))
end
