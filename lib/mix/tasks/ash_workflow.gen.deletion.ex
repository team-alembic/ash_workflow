defmodule Mix.Tasks.AshWorkflow.Gen.Deletion.Docs do
  @moduledoc false

  def short_doc do
    "Adds a deletion workflow to a resource"
  end

  def example do
    "mix ash_workflow.gen.deletion MyApp.Accounts.Account --grace-period 30d"
  end

  def long_doc do
    """
    #{short_doc()}

    Generates a deletion resource that waits a grace period after a deletion
    is requested, then runs a `:purge` action and moves to `:deleted`. A
    request can be restored during the grace period. The subject gains
    `has_one :deletion` and a `pending_deletion?` calculation. When the
    subject does not exist, it is created with `mix ash.gen.resource` first.

    The generated `:purge` action is empty. The application decides what a
    purge erases. The `:request` action has no policy, so the application
    decides who may request a deletion. Nobody may request a deletion again,
    retry a purge or restore a deletion until the application defines who can,
    in the generated `Checks.CanRequestDeletion` and `Checks.CanRestore`
    modules.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--grace-period` - required. How long a request waits before the purge
      runs, given as `30m`, `12h`, `2d` or `2w`.
    * `--max-attempts` - how many times the purge runs before the deletion
      moves to `:purge_failed`. Defaults to `3`.
    * `--module` - the deletion resource's module name. Defaults to the
      subject's name with `Deletion` appended.
    * `--domain` - the domain for a subject the task creates. Required only
      when the subject does not exist.
    * `--transition-log` - also generates a transition log for the deletion
      with `mix ash_workflow.gen.transition_log`. Defaults to `true`.
    """
  end
end

# Guarded on the struct this task builds rather than on `Igniter` itself. See
# `Mix.Tasks.AshWorkflow.Gen.TransitionLog` for why.
if Code.ensure_loaded?(Igniter.Mix.Task.Info) do
  defmodule Mix.Tasks.AshWorkflow.Gen.Deletion do
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
          grace_period: :string,
          max_attempts: :integer,
          module: :string,
          domain: :string,
          transition_log: :boolean
        ],
        defaults: [max_attempts: 3, transition_log: true],
        required: [:grace_period]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      subject = ProjectModule.parse(igniter.args.positional.subject)

      with {:ok, grace_period} <-
             Recipe.parse_duration(options[:grace_period], "--grace-period"),
           :ok <- validate_max_attempts(options[:max_attempts]) do
        deletion = deletion_module(subject, options[:module])

        config = %{
          subject: subject,
          deletion: deletion,
          can_request_deletion: Module.concat([deletion, Checks, CanRequestDeletion]),
          can_restore: Module.concat([deletion, Checks, CanRestore]),
          grace_period: grace_period,
          max_attempts: options[:max_attempts],
          transition_log?: options[:transition_log]
        }

        case Recipe.ensure_subject(
               igniter,
               subject,
               options[:domain],
               "deletion",
               []
             ) do
          {:ok, igniter, storage} -> generate_with_key_type(igniter, config, storage)
          {:error, igniter} -> igniter
        end
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp validate_max_attempts(count) when count >= 1, do: :ok

    defp validate_max_attempts(count),
      do: {:error, "--max-attempts must be at least 1, got: #{count}"}

    defp deletion_module(subject, nil), do: Module.concat([inspect(subject) <> "Deletion"])
    defp deletion_module(_subject, module), do: ProjectModule.parse(module)

    # A subject created in this run does not compile yet and gets
    # ash.gen.resource's uuid_v7 key.
    defp generate_with_key_type(igniter, config, storage) do
      case Recipe.key_type(config.subject, "deletion", :uuid_v7) do
        {:ok, key_type} -> generate(igniter, Map.put(config, :key_type, key_type), storage)
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp generate(igniter, config, storage) do
      {exists?, igniter} = ProjectModule.module_exists(igniter, config.deletion)

      igniter
      |> Recipe.add_subject_edits(
        config.subject,
        [
          deletion: """
          has_one :deletion, #{inspect(config.deletion)} do
            destination_attribute :subject_id
            public? true
          end
          """
        ],
        pending_deletion?:
          "calculate :pending_deletion?, :boolean, expr(deletion.state in [:requested, :purging, :purge_failed])"
      )
      |> then(fn igniter ->
        if exists?, do: igniter, else: create_deletion(igniter, config, storage)
      end)
    end

    defp create_deletion(igniter, config, storage) do
      igniter
      |> ProjectModule.create_module(config.deletion, deletion_contents(config, storage))
      |> ProjectModule.create_module(
        config.can_request_deletion,
        Recipe.deny_check_contents(
          "Decides who may request again or retry the purge of an `#{inspect(config.deletion)}`.",
          "actor may request this deletion again or retry its purge"
        )
      )
      |> ProjectModule.create_module(
        config.can_restore,
        Recipe.deny_check_contents(
          "Decides who may restore an `#{inspect(config.deletion)}`.",
          "actor may restore this deletion"
        )
      )
      |> DomainIgniter.add_resource_reference(storage.domain, config.deletion)
      |> compose_transition_log(config)
      |> Igniter.add_notice("""
      Generated #{inspect(config.deletion)} to delete #{inspect(config.subject)}.

      A purge erases nothing yet. Fill in the :purge action in \
      #{inspect(config.deletion)} with what deleting a subject means.

      Nobody can request a deletion again or restore one yet. Define who may in \
      #{inspect(config.can_request_deletion)} and #{inspect(config.can_restore)}, \
      which deny everyone as generated.
      """)
    end

    defp compose_transition_log(igniter, %{transition_log?: false}), do: igniter

    defp compose_transition_log(igniter, config),
      do: Recipe.compose_transition_log(igniter, config.deletion, nil)

    defp deletion_contents(config, storage) do
      """
      use Ash.Resource,
        domain: #{inspect(storage.domain)},
        #{Recipe.data_layer_option(storage)}
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshWorkflow, AshOban]

      #{Recipe.postgres_block(storage, config.deletion, Recipe.identity_index_name(config.deletion, :unique_subject))}

      workflow do
        step :requested do
          transition :restore, to: :restored

          timeout :purging, fire_after: #{inspect(config.grace_period)}, field: :requested_at, transition_to: :purging
        end

        step :purging do
          action :purge
          on_success :deleted
          on_error :purge_failed

          retry do
            max_attempts #{config.max_attempts}
          end
        end

        step :purge_failed do
          transition :retry_purge, to: :purging
        end

        step :restored do
          transition :request_again, to: :requested
        end

        step :deleted, terminal: true
      end

      code_interface do
        define :request, args: [:subject_id]
        define :restore
        define :request_again
        define :retry_purge
      end

      actions do
        defaults [:read]

        create :request do
          accept [:subject_id]
          change set_attribute(:requested_at, &DateTime.utc_now/0)
        end

        update :request_again do
          require_atomic? false
          change set_attribute(:requested_at, &DateTime.utc_now/0)
        end

        # Runs once the grace period has passed. Add the changes that erase or
        # anonymise the subject; the generator deletes nothing itself.
        update :purge do
          require_atomic? false
        end
      end

      policies do
        policy action([:request_again, :retry_purge]) do
          authorize_if #{inspect(config.can_request_deletion)}
        end

        policy action(:restore) do
          authorize_if #{inspect(config.can_restore)}
        end
      end

      attributes do
        uuid_v7_primary_key :id
        attribute :requested_at, :utc_datetime_usec, allow_nil?: false, public?: true
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
  end
else
  defmodule Mix.Tasks.AshWorkflow.Gen.Deletion do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_workflow.gen.deletion' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
