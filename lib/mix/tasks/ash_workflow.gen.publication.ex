defmodule Mix.Tasks.AshWorkflow.Gen.Publication.Docs do
  @moduledoc false

  def short_doc do
    "Adds a publication workflow to a resource"
  end

  def example do
    "mix ash_workflow.gen.publication MyApp.Blog.Post --with-unpublish-at"
  end

  def long_doc do
    """
    #{short_doc()}

    Generates a publication resource that moves from `:draft` to `:scheduled`,
    goes `:published` once its `publish_at` passes, and can be unpublished and
    republished. The subject gains `has_one :publication` and a `published?`
    calculation. When the subject does not exist, it is created with
    `mix ash.gen.resource` first.

    Nobody may create a publication until the application defines who can, in
    the generated `Checks.CanCreate` module. Nobody may schedule, publish or
    unpublish until it does the same in `Checks.CanPublish`.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--module` - the publication resource's module name. Defaults to the
      subject's name with `Publication` appended.
    * `--domain` - the domain for a subject the task creates. Required only
      when the subject does not exist.
    * `--with-unpublish-at` - generates an `unpublish_at` attribute, set when
      scheduling or republishing, that moves a publication to `:unpublished`
      once it passes. Defaults to `false`.
    * `--transition-log` - also generates a transition log for the publication
      with `mix ash_workflow.gen.transition_log`. Defaults to `true`.
    """
  end
end

# Guarded on the struct this task builds rather than on `Igniter` itself. See
# `Mix.Tasks.AshWorkflow.Gen.TransitionLog` for why.
if Code.ensure_loaded?(Igniter.Mix.Task.Info) do
  defmodule Mix.Tasks.AshWorkflow.Gen.Publication do
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
          with_unpublish_at: :boolean,
          transition_log: :boolean
        ],
        defaults: [with_unpublish_at: false, transition_log: true]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      subject = ProjectModule.parse(igniter.args.positional.subject)
      publication = publication_module(subject, options[:module])

      config = %{
        subject: subject,
        publication: publication,
        can_create: Module.concat([publication, Checks, CanCreate]),
        can_publish: Module.concat([publication, Checks, CanPublish]),
        unpublish_at?: options[:with_unpublish_at],
        transition_log?: options[:transition_log]
      }

      case Recipe.ensure_subject(
             igniter,
             subject,
             options[:domain],
             "publication",
             []
           ) do
        {:ok, igniter, storage} -> generate_with_key_type(igniter, config, storage)
        {:error, igniter} -> igniter
      end
    end

    # A subject created in this run does not compile yet and gets
    # ash.gen.resource's uuid_v7 key.
    defp generate_with_key_type(igniter, config, storage) do
      case Recipe.key_type(config.subject, "publication", :uuid_v7) do
        {:ok, key_type} -> generate(igniter, Map.put(config, :key_type, key_type), storage)
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp publication_module(subject, nil),
      do: Module.concat([inspect(subject) <> "Publication"])

    defp publication_module(_subject, module), do: ProjectModule.parse(module)

    defp generate(igniter, config, storage) do
      {exists?, igniter} = ProjectModule.module_exists(igniter, config.publication)

      igniter
      |> Recipe.add_subject_edits(
        config.subject,
        [
          publication: """
          has_one :publication, #{inspect(config.publication)} do
            destination_attribute :subject_id
            public? true
          end
          """
        ],
        published?:
          "calculate :published?, :boolean, expr(publication.state == :published || false)"
      )
      |> then(fn igniter ->
        if exists?, do: igniter, else: create_publication(igniter, config, storage)
      end)
    end

    defp create_publication(igniter, config, storage) do
      igniter
      |> ProjectModule.create_module(
        config.publication,
        publication_contents(config, storage)
      )
      |> ProjectModule.create_module(config.can_create, can_create_contents(config))
      |> ProjectModule.create_module(config.can_publish, can_publish_contents(config))
      |> DomainIgniter.add_resource_reference(storage.domain, config.publication)
      |> compose_transition_log(config)
      |> Igniter.add_notice("""
      Generated #{inspect(config.publication)} to publish #{inspect(config.subject)}.

      Nobody can create, schedule, publish or unpublish yet. Define who may \
      create a publication in #{inspect(config.can_create)} and who may \
      publish in #{inspect(config.can_publish)}. Both deny everyone as generated.
      """)
    end

    defp compose_transition_log(igniter, %{transition_log?: false}), do: igniter

    defp compose_transition_log(igniter, config),
      do: Recipe.compose_transition_log(igniter, config.publication, nil)

    defp publication_contents(config, storage) do
      """
      use Ash.Resource,
        domain: #{inspect(storage.domain)},
        #{Recipe.data_layer_option(storage)}
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshWorkflow, AshOban]

      #{Recipe.postgres_block(storage, config.publication, Recipe.identity_index_name(config.publication, :unique_subject))}

      workflow do
        step :draft do
          transition :schedule, to: :scheduled
          transition :publish_now, to: :published
        end

        step :scheduled do
          transition :reschedule, to: :scheduled
          transition :unschedule, to: :draft
          transition :publish_now, to: :published

          timeout :published do
            fire_at :publish_at
            transition_to :published
          end
        end

        step :published do
          transition :unpublish, to: :unpublished

          #{unpublished_timeout(config.unpublish_at?)}
        end

        step :unpublished do
          transition :republish, to: :published
        end
      end

      code_interface do
        define :create, args: [:subject_id]
        #{schedule_interface(config.unpublish_at?)}
        define :reschedule, args: [:publish_at]
        #{republish_interface(config.unpublish_at?)}
      end

      actions do
        defaults [:read]

        create :create do
          accept [:subject_id]
        end

        #{actions(config.unpublish_at?)}
      end

      policies do
        #{Recipe.create_policy(:create, config.can_create)}

        policy action([:schedule, :reschedule, :unschedule, :publish_now, :unpublish, :republish]) do
          authorize_if #{inspect(config.can_publish)}
        end
      end

      attributes do
        uuid_v7_primary_key :id
        attribute :publish_at, :utc_datetime_usec, public?: true
        #{unpublish_at_attribute(config.unpublish_at?)}
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

    defp unpublished_timeout(false), do: ""

    defp unpublished_timeout(true) do
      """
      timeout :unpublished do
        fire_at :unpublish_at
        transition_to :unpublished
      end
      """
    end

    defp schedule_interface(false), do: "define :schedule, args: [:publish_at]"

    defp schedule_interface(true),
      do: "define :schedule, args: [:publish_at, {:optional, :unpublish_at}]"

    defp republish_interface(false), do: ""
    defp republish_interface(true), do: "define :republish, args: [{:optional, :unpublish_at}]"

    defp actions(false) do
      """
      update :schedule do
        require_atomic? false
        argument :publish_at, :utc_datetime_usec, allow_nil?: false
        change set_attribute(:publish_at, arg(:publish_at))
      end

      update :reschedule do
        require_atomic? false
        argument :publish_at, :utc_datetime_usec, allow_nil?: false
        change set_attribute(:publish_at, arg(:publish_at))
      end

      update :unschedule do
        require_atomic? false
        change set_attribute(:publish_at, nil)
      end
      """
    end

    defp actions(true) do
      """
      update :schedule do
        require_atomic? false
        argument :publish_at, :utc_datetime_usec, allow_nil?: false
        argument :unpublish_at, :utc_datetime_usec
        change set_attribute(:publish_at, arg(:publish_at))
        change set_attribute(:unpublish_at, arg(:unpublish_at))
        validate compare(:unpublish_at, greater_than: :publish_at), where: present(:unpublish_at)
      end

      update :reschedule do
        require_atomic? false
        argument :publish_at, :utc_datetime_usec, allow_nil?: false
        change set_attribute(:publish_at, arg(:publish_at))
        validate compare(:unpublish_at, greater_than: :publish_at), where: present(:unpublish_at)
      end

      update :unschedule do
        require_atomic? false
        change set_attribute(:publish_at, nil)
        change set_attribute(:unpublish_at, nil)
      end

      update :republish do
        require_atomic? false
        argument :unpublish_at, :utc_datetime_usec
        change set_attribute(:unpublish_at, arg(:unpublish_at))
      end
      """
    end

    defp unpublish_at_attribute(false), do: ""

    defp unpublish_at_attribute(true),
      do: "attribute :unpublish_at, :utc_datetime_usec, public?: true"

    defp can_create_contents(config) do
      Recipe.deny_check_contents(
        "Decides who may create a `#{inspect(config.publication)}` for a subject.",
        "actor may create a publication for this subject"
      )
    end

    defp can_publish_contents(config) do
      Recipe.deny_check_contents(
        "Decides who may schedule, publish or unpublish a `#{inspect(config.publication)}`.",
        "actor may publish this publication"
      )
    end
  end
else
  defmodule Mix.Tasks.AshWorkflow.Gen.Publication do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_workflow.gen.publication' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
