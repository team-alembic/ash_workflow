defmodule Mix.Tasks.AshWorkflow.Gen.Sync.Docs do
  @moduledoc false

  def short_doc do
    "Adds a sync workflow to a resource"
  end

  def example do
    "mix ash_workflow.gen.sync MyApp.Sales.Customer --max-attempts 5 --backoff 30s"
  end

  def long_doc do
    """
    #{short_doc()}

    Generates a sync resource whose `:syncing` step runs a `:push` action,
    retries it on failure, and moves to `:synced` or `:failed`. A `resync`
    returns a synced or failed record to `:syncing`. The subject gains
    `has_one :sync` and a `synced?` calculation. When the subject does not
    exist, it is created with `mix ash.gen.resource` first.

    The generated `:push` action only stamps `last_synced_at`. Add the change
    that calls the external system to it. Nobody may resync until the
    application defines who can, in the generated `Checks.CanResync` module.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--module` - the sync resource's module name. Defaults to the subject's
      name with `Sync` appended.
    * `--domain` - the domain for a subject the task creates. Required only
      when the subject does not exist.
    * `--max-attempts` - how many times `:push` runs before the sync moves to
      `:failed`. Defaults to `5`.
    * `--backoff` - the delay between attempts, given as `10s`, `30m`, `12h`,
      `2d`, `2w` or `exponential`. Defaults to `exponential`.
    * `--transition-log` - also generates a transition log for the sync with
      `mix ash_workflow.gen.transition_log`. Defaults to `true`.
    """
  end
end

# Guarded on the struct this task builds rather than on `Igniter` itself. See
# `Mix.Tasks.AshWorkflow.Gen.TransitionLog` for why.
if Code.ensure_loaded?(Igniter.Mix.Task.Info) do
  defmodule Mix.Tasks.AshWorkflow.Gen.Sync do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"
    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Ash.Domain.Igniter, as: DomainIgniter
    alias Igniter.Project.Module, as: ProjectModule
    alias Mix.AshWorkflow.Recipe

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example: __MODULE__.Docs.example(),
        positional: [:subject],
        composes: ["ash.gen.resource", "ash_workflow.gen.transition_log"],
        schema: [
          module: :string,
          domain: :string,
          max_attempts: :integer,
          backoff: :string,
          transition_log: :boolean
        ],
        defaults: [max_attempts: 5, backoff: "exponential", transition_log: true]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      subject = ProjectModule.parse(igniter.args.positional.subject)

      with :ok <- Recipe.validate_max_attempts(options[:max_attempts]),
           {:ok, backoff} <- Recipe.parse_backoff(options[:backoff], "--backoff") do
        sync = sync_module(subject, options[:module])

        config = %{
          subject: subject,
          sync: sync,
          can_resync: Module.concat([sync, Checks, CanResync]),
          max_attempts: options[:max_attempts],
          backoff: backoff,
          transition_log?: options[:transition_log]
        }

        case Recipe.ensure_subject(igniter, subject, options[:domain], "sync", []) do
          {:ok, igniter, storage} -> generate_with_key_type(igniter, config, storage)
          {:error, igniter} -> igniter
        end
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp sync_module(subject, nil), do: Module.concat([inspect(subject) <> "Sync"])
    defp sync_module(_subject, module), do: ProjectModule.parse(module)

    # A subject created in this run does not compile yet and gets
    # ash.gen.resource's uuid_v7 key.
    defp generate_with_key_type(igniter, config, storage) do
      case Recipe.key_type(config.subject, "sync", :uuid_v7) do
        {:ok, key_type} -> generate(igniter, Map.put(config, :key_type, key_type), storage)
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp generate(igniter, config, storage) do
      {exists?, igniter} = ProjectModule.module_exists(igniter, config.sync)

      igniter
      |> Recipe.add_subject_edits(
        config.subject,
        [
          sync: """
          has_one :sync, #{inspect(config.sync)} do
            destination_attribute :subject_id
            public? true
          end
          """
        ],
        synced?: "calculate :synced?, :boolean, expr(sync.state == :synced)"
      )
      |> then(fn igniter ->
        if exists?, do: igniter, else: create_sync(igniter, config, storage)
      end)
    end

    defp create_sync(igniter, config, storage) do
      igniter
      |> ProjectModule.create_module(config.sync, sync_contents(config, storage))
      |> ProjectModule.create_module(config.can_resync, can_resync_contents(config))
      |> DomainIgniter.add_resource_reference(storage.domain, config.sync)
      |> compose_transition_log(config)
      |> Igniter.add_notice("""
      Generated #{inspect(config.sync)} to sync #{inspect(config.subject)}.

      The :push action only stamps last_synced_at, so every sync reaches \
      :synced until you add the change that calls the external system.

      Nobody can resync yet. Define who may resync in \
      #{inspect(config.can_resync)}, which denies everyone as generated.
      """)
    end

    defp compose_transition_log(igniter, %{transition_log?: false}), do: igniter

    defp compose_transition_log(igniter, config),
      do: Recipe.compose_transition_log(igniter, config.sync, nil)

    defp sync_contents(config, storage) do
      """
      use Ash.Resource,
        domain: #{inspect(storage.domain)},
        #{Recipe.data_layer_option(storage)}
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshWorkflow, AshOban]

      #{Recipe.postgres_block(storage, config.sync, Recipe.identity_index_name(config.sync, :unique_subject))}

      workflow do
        step :syncing do
          action :push
          on_success :synced
          on_error :failed

          retry do
            max_attempts #{config.max_attempts}
            backoff #{inspect(config.backoff)}
          end
        end

        step :synced do
          transition :resync, to: :syncing
        end

        step :failed do
          transition :resync, to: :syncing
        end
      end

      code_interface do
        define :create, args: [:subject_id]
        define :resync
      end

      actions do
        defaults [:read]

        create :create do
          accept [:subject_id]
        end

        update :push do
          require_atomic? false
          change set_attribute(:last_synced_at, &DateTime.utc_now/0)
        end
      end

      policies do
        policy action(:resync) do
          authorize_if #{inspect(config.can_resync)}
        end
      end

      attributes do
        uuid_v7_primary_key :id
        attribute :external_id, :string, public?: true
        attribute :last_synced_at, :utc_datetime_usec, public?: true
        timestamps()
      end

      relationships do
        #{Recipe.belongs_to(:subject, config.subject, config.key_type)}
      end

      identities do
        identity :unique_subject, [:subject_id]#{Recipe.pre_check_with(storage)}
      end
      """
    end

    defp can_resync_contents(config) do
      Recipe.deny_check_contents(
        "Decides who may resync a `#{inspect(config.sync)}`.",
        "actor may resync this sync"
      )
    end
  end
else
  defmodule Mix.Tasks.AshWorkflow.Gen.Sync do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_workflow.gen.sync' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
