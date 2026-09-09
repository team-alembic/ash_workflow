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

  ## Module names

  Worker and scheduler module names are derived from the resource, the step and
  the timeout, and are set explicitly rather than left to ash_oban's defaults so
  that renaming a step does not leave jobs pointing at a module that no longer
  exists.
  """
  use AshWorkflow.Scheduler

  alias AshWorkflow.Scheduler.Work
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @impl AshWorkflow.Scheduler
  def transform(dsl, works, opts) do
    with :ok <- verify_extension(dsl) do
      {:ok, Enum.reduce(works, dsl, &add_trigger(&2, &1, opts))}
    end
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
        where: work.match,
        queue: queue(dsl, opts),
        on_error: work.on_error,
        trigger_once?: work.once?,
        worker_module_name: module_name(work, Workers),
        scheduler_module_name: module_name(work, Schedulers),
        scheduler_cron: check_interval(dsl, work, opts),
        stream_with: :keyset
      )

    Transformer.add_entity(dsl, [:oban, :triggers], trigger)
  end

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
