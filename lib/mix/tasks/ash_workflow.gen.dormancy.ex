defmodule Mix.Tasks.AshWorkflow.Gen.Dormancy.Docs do
  @moduledoc false

  def short_doc do
    "Adds a dormancy workflow to a resource"
  end

  def example do
    "mix ash_workflow.gen.dormancy MyApp.Accounts.Account --dormant-after 90d --archive-after 180d"
  end

  def long_doc do
    """
    #{short_doc()}

    Generates a dormancy resource that moves to `:dormant` once its
    `last_activity_at` is older than `--dormant-after`, and back to `:active`
    when it is reactivated. The application calls its `record_activity`
    action whenever the subject is used. The subject gains `has_one :dormancy`
    and a `dormant?` calculation. When the subject does not exist, it is
    created with `mix ash.gen.resource` first.

    Nobody may reactivate until the application defines who can, in the
    generated `Checks.CanReactivate` module.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--dormant-after` - moves a dormancy to `:dormant` once
      `last_activity_at` is this old, given as `10s`, `30m`, `12h`, `2d` or
      `2w`.
      Required.
    * `--archive-after` - moves a dormancy to `:archived` once it has been
      `:dormant` this long. Without it, no `:archived` step is generated.
    * `--module` - the dormancy resource's module name. Defaults to the
      subject's name with `Dormancy` appended.
    * `--domain` - the domain for a subject the task creates. Required only
      when the subject does not exist.
    * `--transition-log` - also generates a transition log for the dormancy
      with `mix ash_workflow.gen.transition_log`. Defaults to `true`.
    """
  end
end

# Guarded on the struct this task builds rather than on `Igniter` itself. See
# `Mix.Tasks.AshWorkflow.Gen.TransitionLog` for why.
if Code.ensure_loaded?(Igniter.Mix.Task.Info) do
  defmodule Mix.Tasks.AshWorkflow.Gen.Dormancy do
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
          dormant_after: :string,
          archive_after: :string,
          module: :string,
          domain: :string,
          transition_log: :boolean
        ],
        defaults: [transition_log: true],
        required: [:dormant_after]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      subject = ProjectModule.parse(igniter.args.positional.subject)

      with {:ok, dormant_after} <-
             Recipe.parse_duration(options[:dormant_after], "--dormant-after"),
           {:ok, archive_after} <-
             Recipe.parse_duration(options[:archive_after], "--archive-after") do
        dormancy = dormancy_module(subject, options[:module])

        config = %{
          subject: subject,
          dormancy: dormancy,
          can_reactivate: Module.concat([dormancy, Checks, CanReactivate]),
          dormant_after: dormant_after,
          archive_after: archive_after,
          transition_log?: options[:transition_log]
        }

        case Recipe.ensure_subject(
               igniter,
               subject,
               options[:domain],
               "dormancy",
               []
             ) do
          {:ok, igniter, storage} -> generate_with_key_type(igniter, config, storage)
          {:error, igniter} -> igniter
        end
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp dormancy_module(subject, nil), do: Module.concat([inspect(subject) <> "Dormancy"])
    defp dormancy_module(_subject, module), do: ProjectModule.parse(module)

    # A subject created in this run does not compile yet and gets
    # ash.gen.resource's uuid_v7 key.
    defp generate_with_key_type(igniter, config, storage) do
      case Recipe.key_type(config.subject, "dormancy", :uuid_v7) do
        {:ok, key_type} -> generate(igniter, Map.put(config, :key_type, key_type), storage)
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp generate(igniter, config, storage) do
      {exists?, igniter} = ProjectModule.module_exists(igniter, config.dormancy)

      igniter
      |> Recipe.add_subject_edits(
        config.subject,
        [
          dormancy: """
          has_one :dormancy, #{inspect(config.dormancy)} do
            destination_attribute :subject_id
            public? true
          end
          """
        ],
        dormant?: "calculate :dormant?, :boolean, #{dormant_expr(config.archive_after)}"
      )
      |> then(fn igniter ->
        if exists?, do: igniter, else: create_dormancy(igniter, config, storage)
      end)
    end

    # An archived subject has been dormant for longer, so it counts as dormant.
    defp dormant_expr(nil), do: "expr(dormancy.state == :dormant)"
    defp dormant_expr(_archive_after), do: "expr(dormancy.state in [:dormant, :archived])"

    defp create_dormancy(igniter, config, storage) do
      igniter
      |> ProjectModule.create_module(config.dormancy, dormancy_contents(config, storage))
      |> ProjectModule.create_module(config.can_reactivate, can_reactivate_contents(config))
      |> DomainIgniter.add_resource_reference(storage.domain, config.dormancy)
      |> compose_transition_log(config)
      |> Igniter.add_notice("""
      Generated #{inspect(config.dormancy)} to track activity on #{inspect(config.subject)}.

      Call record_activity whenever #{inspect(config.subject)} is used, or every \
      dormancy goes dormant #{format_duration(config.dormant_after)} after it is created.

      Nobody can reactivate a dormancy yet. Define who may reactivate in \
      #{inspect(config.can_reactivate)}, which denies everyone as generated.
      """)
    end

    defp format_duration({count, unit}), do: "#{count} #{unit}"

    defp compose_transition_log(igniter, %{transition_log?: false}), do: igniter

    defp compose_transition_log(igniter, config),
      do: Recipe.compose_transition_log(igniter, config.dormancy, nil)

    defp dormancy_contents(config, storage) do
      """
      use Ash.Resource,
        domain: #{inspect(storage.domain)},
        #{Recipe.data_layer_option(storage)}
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshWorkflow, AshOban]

      #{Recipe.postgres_block(storage, config.dormancy, Recipe.identity_index_name(config.dormancy, :unique_subject))}

      workflow do
        #{steps(config)}
      end

      code_interface do
        define :create, args: [:subject_id]
        define :record_activity
        define :reactivate
      end

      actions do
        defaults [:read]

        create :create do
          accept [:subject_id, :last_activity_at]
        end

        update :record_activity do
          require_atomic? false
          change set_attribute(:last_activity_at, &DateTime.utc_now/0)
        end

        update :reactivate do
          require_atomic? false
          change set_attribute(:last_activity_at, &DateTime.utc_now/0)
        end
      end

      policies do
        policy action(:reactivate) do
          authorize_if #{inspect(config.can_reactivate)}
        end

        policy action(:record_activity) do
          authorize_if always()
        end
      end

      attributes do
        uuid_v7_primary_key :id

        attribute :last_activity_at, :utc_datetime_usec,
          allow_nil?: false,
          default: &DateTime.utc_now/0,
          public?: true

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

    defp steps(config) do
      """
      step :active do
        timeout :dormant,
          fire_after: #{inspect(config.dormant_after)},
          field: :last_activity_at,
          transition_to: :dormant
      end

      #{dormant_step(config.archive_after)}
      """
    end

    defp dormant_step(nil) do
      """
      step :dormant do
        transition :reactivate, to: :active
      end
      """
    end

    defp dormant_step(archive_after) do
      """
      step :dormant do
        transition :reactivate, to: :active

        timeout :archived, fire_after: #{inspect(archive_after)}, transition_to: :archived
      end

      step :archived do
        transition :reactivate, to: :active
      end
      """
    end

    defp can_reactivate_contents(config) do
      Recipe.deny_check_contents(
        "Decides who may reactivate an `#{inspect(config.dormancy)}`.",
        "actor may reactivate this dormancy"
      )
    end
  end
else
  defmodule Mix.Tasks.AshWorkflow.Gen.Dormancy do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_workflow.gen.dormancy' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
