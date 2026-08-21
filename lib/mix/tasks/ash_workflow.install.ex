defmodule Mix.Tasks.AshWorkflow.Install.Docs do
  @moduledoc false

  def short_doc do
    "Installs AshWorkflow, along with AshOban, AshStateMachine and Oban"
  end

  def example do
    "mix igniter.install ash_workflow"
  end

  def long_doc do
    """
    #{short_doc()}

    AshWorkflow generates `ash_state_machine` and `ash_oban` DSL for you, so
    this installer sets up everything those need to actually run:

    - adds `ash_oban` and `ash_state_machine` as dependencies and composes
      `ash_oban.install`, which configures Oban, the cron plugin and
      `:ash_domains`
    - adds the queue AshWorkflow's generated triggers publish to
    - imports AshWorkflow into your `.formatter.exs` so the workflow DSL
      formats without parentheses

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--queue` - the Oban queue for generated workflow triggers.
      Defaults to `workflow`, matching the DSL's default.
    * `--queue-concurrency` - concurrency for that queue. Defaults to `10`.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshWorkflow.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"
    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example: __MODULE__.Docs.example(),
        installs: [
          {:ash_oban, "~> 0.2"},
          {:ash_state_machine, "~> 0.2"}
        ],
        composes: ["ash_oban.install"],
        schema: [queue: :string, queue_concurrency: :integer],
        defaults: [queue: "workflow", queue_concurrency: 10]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      queue = String.to_atom(options[:queue])
      concurrency = options[:queue_concurrency]
      app_name = Igniter.Project.Application.app_name(igniter)

      igniter
      |> Igniter.compose_task("ash_oban.install", [])
      |> Igniter.Project.Formatter.import_dep(:ash_workflow)
      |> add_queue(app_name, queue, concurrency)
      |> Igniter.add_notice("""
      AshWorkflow installed.

      Add the extension to a resource to define a workflow:

          use Ash.Resource,
            domain: MyApp.Domain,
            data_layer: AshPostgres.DataLayer,
            extensions: [AshWorkflow]

          workflow do
            step :review do
              transition :approve, to: :approved
              transition :reject, to: :rejected
            end

            step :approved, terminal: true
            step :rejected, terminal: true
          end

      Generated triggers publish to the `:#{queue}` queue. Workflows are
      started through your own create action — creating a record enters the
      initial step. Run `mix ash.codegen` to generate the migration for the
      `state` and `state_entered_at` attributes.
      """)
    end

    # AshWorkflow's triggers default to the `:workflow` queue, which Oban will
    # not process unless it is declared. Leave an existing entry alone so
    # re-running the installer never lowers a tuned concurrency.
    defp add_queue(igniter, app_name, queue, concurrency) do
      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        app_name,
        [Oban, :queues, queue],
        concurrency,
        updater: &{:ok, &1}
      )
    end
  end
else
  defmodule Mix.Tasks.AshWorkflow.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_workflow.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
