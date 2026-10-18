defmodule Mix.Tasks.AshWorkflow.Gen.Acknowledgement.Docs do
  @moduledoc false

  def short_doc do
    "Adds an acknowledgement workflow to a resource"
  end

  def example do
    "mix ash_workflow.gen.acknowledgement MyApp.Policies.Policy --person MyApp.Accounts.User --overdue-after 14d"
  end

  def long_doc do
    """
    #{short_doc()}

    Generates an acknowledgement resource with one row per person asked to
    acknowledge a subject. Only the row's own person may acknowledge it.
    The subject gains `has_many :acknowledgements` and an
    `acknowledged_by_actor?` calculation. When the subject does not exist, it
    is created with `mix ash.gen.resource` first.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--person` - required. The actor resource. Each acknowledgement belongs
      to one person.
    * `--module` - the acknowledgement resource's module name. Defaults to
      the subject's name with `Acknowledgement` appended.
    * `--domain` - the domain for a subject the task creates. Required only
      when the subject does not exist.
    * `--overdue-after` - moves an unacknowledged request to `:overdue` this
      long after it was requested, given as `10s`, `30m`, `12h`, `2d` or
      `2w`. Without it, no `:overdue` step is generated.
    * `--transition-log` - also generates a transition log for the
      acknowledgement with `mix ash_workflow.gen.transition_log`. Defaults to
      `true`.
    """
  end
end

# Guarded on the struct this task builds rather than on `Igniter` itself. See
# `Mix.Tasks.AshWorkflow.Gen.TransitionLog` for why.
if Code.ensure_loaded?(Igniter.Mix.Task.Info) do
  defmodule Mix.Tasks.AshWorkflow.Gen.Acknowledgement do
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
          person: :string,
          module: :string,
          domain: :string,
          overdue_after: :string,
          transition_log: :boolean
        ],
        defaults: [transition_log: true],
        required: [:person]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      subject = ProjectModule.parse(igniter.args.positional.subject)

      case Recipe.parse_duration(options[:overdue_after], "--overdue-after") do
        {:ok, overdue_after} ->
          person = ProjectModule.parse(options[:person])

          config = %{
            subject: subject,
            person: person,
            acknowledgement: acknowledgement_module(subject, options[:module]),
            overdue_after: overdue_after,
            transition_log?: options[:transition_log]
          }

          # A created subject stores its records the same way the person does.
          case Recipe.ensure_subject(
                 igniter,
                 subject,
                 options[:domain],
                 "acknowledgement",
                 [person]
               ) do
            {:ok, igniter, storage} -> generate_with_key_types(igniter, config, storage)
            {:error, igniter} -> igniter
          end

        {:error, message} ->
          Igniter.add_issue(igniter, message)
      end
    end

    defp acknowledgement_module(subject, nil),
      do: Module.concat([inspect(subject) <> "Acknowledgement"])

    defp acknowledgement_module(_subject, module), do: ProjectModule.parse(module)

    # A subject created in this run does not compile yet and gets
    # ash.gen.resource's uuid_v7 key.
    defp generate_with_key_types(igniter, config, storage) do
      with {:ok, subject_type} <- Recipe.key_type(config.subject, "acknowledgement", :uuid_v7),
           {:ok, person_type} <- Recipe.key_type(config.person, "acknowledgement", nil) do
        key_types = %{subject: subject_type, person: person_type}
        generate(igniter, Map.put(config, :key_types, key_types), storage)
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp generate(igniter, config, storage) do
      {exists?, igniter} = ProjectModule.module_exists(igniter, config.acknowledgement)

      igniter
      |> Recipe.add_subject_edits(
        config.subject,
        [
          acknowledgements: """
          has_many :acknowledgements, #{inspect(config.acknowledgement)} do
            destination_attribute :subject_id
            public? true
          end
          """
        ],
        acknowledged_by_actor?:
          "calculate :acknowledged_by_actor?, :boolean, expr(exists(acknowledgements, person_id == ^actor(:id) and state == :acknowledged) || false)"
      )
      |> then(fn igniter ->
        if exists?, do: igniter, else: create_acknowledgement(igniter, config, storage)
      end)
    end

    defp create_acknowledgement(igniter, config, storage) do
      igniter
      |> ProjectModule.create_module(
        config.acknowledgement,
        acknowledgement_contents(config, storage)
      )
      |> DomainIgniter.add_resource_reference(storage.domain, config.acknowledgement)
      |> compose_transition_log(config)
      |> Igniter.add_notice("""
      Generated #{inspect(config.acknowledgement)} to acknowledge #{inspect(config.subject)}.

      Only the person a request was opened for may acknowledge it, as the \
      policy on :acknowledge states. Open requests with request/3 or \
      request_many/3.
      """)
    end

    defp compose_transition_log(igniter, %{transition_log?: false}), do: igniter

    defp compose_transition_log(igniter, config),
      do: Recipe.compose_transition_log(igniter, config.acknowledgement, config.person)

    defp acknowledgement_contents(config, storage) do
      """
      use Ash.Resource,
        domain: #{inspect(storage.domain)},
        #{Recipe.data_layer_option(storage)}
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshWorkflow, AshOban]

      #{Recipe.postgres_block(storage, config.acknowledgement, Recipe.identity_index_name(config.acknowledgement, :unique_person))}

      workflow do
        step :pending do
          transition :acknowledge, to: :acknowledged

          #{overdue_timeout(config.overdue_after)}
        end

        #{overdue_step(config.overdue_after)}

        step :acknowledged, terminal: true
      end

      code_interface do
        define :request, args: [:subject_id, :person_id]
        define :request_many, action: :request, args: [:subject_id]
        define :acknowledge
      end

      actions do
        defaults [:read]

        # Asking a person who already has a row returns that row unchanged.
        create :request do
          accept [:subject_id, :person_id]
          upsert? true
          upsert_identity :unique_person
          upsert_fields []
          change set_attribute(:requested_at, &DateTime.utc_now/0)
        end

        update :acknowledge do
          require_atomic? false
          change set_attribute(:acknowledged_at, &DateTime.utc_now/0)
        end
      end

      policies do
        policy action(:acknowledge) do
          authorize_if relates_to_actor_via(:person)
        end
      end

      attributes do
        uuid_v7_primary_key :id
        attribute :requested_at, :utc_datetime_usec, allow_nil?: false, public?: true
        attribute :acknowledged_at, :utc_datetime_usec, public?: true
        timestamps()
      end

      relationships do
        #{Recipe.belongs_to(:subject, config.subject, config.key_types.subject)}
        #{Recipe.belongs_to(:person, config.person, config.key_types.person)}
      end

      identities do
        identity :unique_person, [:subject_id, :person_id]#{Recipe.pre_check_with(storage)}
      end
      """
    end

    defp overdue_timeout(nil), do: ""

    defp overdue_timeout(duration) do
      "timeout :overdue, fire_after: #{inspect(duration)}, field: :requested_at, transition_to: :overdue"
    end

    defp overdue_step(nil), do: ""

    defp overdue_step(_duration) do
      """
      step :overdue do
        transition :acknowledge, to: :acknowledged
      end
      """
    end
  end
else
  defmodule Mix.Tasks.AshWorkflow.Gen.Acknowledgement do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_workflow.gen.acknowledgement' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
