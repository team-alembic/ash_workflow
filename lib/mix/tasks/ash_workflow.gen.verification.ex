defmodule Mix.Tasks.AshWorkflow.Gen.Verification.Docs do
  @moduledoc false

  def short_doc do
    "Adds a verification workflow to a resource"
  end

  def example do
    "mix ash_workflow.gen.verification MyApp.Accounts.IdentityDocument --max-attempts 5"
  end

  def long_doc do
    """
    #{short_doc()}

    Generates a verification resource whose `:verifying` step runs a `:verify`
    action the application fills in, such as a call to an outside provider. The
    action's `outcome` routes a verification to `:verified` or `:rejected`, and
    one that fails every attempt moves to `:needs_review` for a person to
    decide. The subject gains `has_many :verifications`,
    `has_one :latest_verification` and a `verified?` calculation. When the
    subject does not exist, it is created with `mix ash.gen.resource` first.

    Nobody may decide a verification in review until the application defines
    who can, in the generated `Checks.CanReview` module.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--module` - the verification resource's module name. Defaults to the
      subject's name with `Verification` appended.
    * `--domain` - the domain for a subject the task creates. Required only
      when the subject does not exist.
    * `--max-attempts` - attempts `:verify` gets before the verification moves
      to `:needs_review`. Defaults to `3`. With `1`, no `retry` block is
      generated.
    * `--transition-log` - also generates a transition log for the
      verification with `mix ash_workflow.gen.transition_log`. Defaults to
      `true`.
    """
  end
end

# Guarded on the struct this task builds rather than on `Igniter` itself. See
# `Mix.Tasks.AshWorkflow.Gen.TransitionLog` for why.
if Code.ensure_loaded?(Igniter.Mix.Task.Info) do
  defmodule Mix.Tasks.AshWorkflow.Gen.Verification do
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
          transition_log: :boolean
        ],
        defaults: [max_attempts: 3, transition_log: true]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      subject = ProjectModule.parse(igniter.args.positional.subject)

      case Recipe.validate_max_attempts(options[:max_attempts]) do
        :ok ->
          verification = verification_module(subject, options[:module])

          config = %{
            subject: subject,
            verification: verification,
            can_review: Module.concat([verification, Checks, CanReview]),
            max_attempts: options[:max_attempts],
            transition_log?: options[:transition_log]
          }

          case Recipe.ensure_subject(
                 igniter,
                 subject,
                 options[:domain],
                 "verification",
                 []
               ) do
            {:ok, igniter, storage} -> generate_with_key_type(igniter, config, storage)
            {:error, igniter} -> igniter
          end

        {:error, message} ->
          Igniter.add_issue(igniter, message)
      end
    end

    defp verification_module(subject, nil),
      do: Module.concat([inspect(subject) <> "Verification"])

    defp verification_module(_subject, module), do: ProjectModule.parse(module)

    # A subject created in this run does not compile yet and gets
    # ash.gen.resource's uuid_v7 key.
    defp generate_with_key_type(igniter, config, storage) do
      case Recipe.key_type(config.subject, "verification", :uuid_v7) do
        {:ok, key_type} -> generate(igniter, Map.put(config, :key_type, key_type), storage)
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp generate(igniter, config, storage) do
      {exists?, igniter} = ProjectModule.module_exists(igniter, config.verification)

      igniter
      |> Recipe.add_subject_edits(
        config.subject,
        [
          verifications: """
          has_many :verifications, #{inspect(config.verification)} do
            destination_attribute :subject_id
            public? true
          end
          """,
          latest_verification: """
          has_one :latest_verification, #{inspect(config.verification)} do
            destination_attribute :subject_id
            from_many? true
            sort inserted_at: :desc
            public? true
          end
          """
        ],
        verified?: "calculate :verified?, :boolean, expr(latest_verification.state == :verified)"
      )
      |> then(fn igniter ->
        if exists?, do: igniter, else: create_verification(igniter, config, storage)
      end)
    end

    defp create_verification(igniter, config, storage) do
      igniter
      |> ProjectModule.create_module(
        config.verification,
        verification_contents(config, storage)
      )
      |> ProjectModule.create_module(config.can_review, can_review_contents(config))
      |> DomainIgniter.add_resource_reference(storage.domain, config.verification)
      |> compose_transition_log(config)
      |> Igniter.add_notice("""
      Generated #{inspect(config.verification)} to verify #{inspect(config.subject)}.

      The :verify action is empty, so every verification lands in :needs_review. \
      Add the change that calls your provider and writes :outcome.

      Nobody can decide a verification in review yet. Define who may in \
      #{inspect(config.can_review)}, which denies everyone as generated.
      """)
    end

    defp compose_transition_log(igniter, %{transition_log?: false}), do: igniter

    defp compose_transition_log(igniter, config),
      do: Recipe.compose_transition_log(igniter, config.verification, nil)

    defp verification_contents(config, storage) do
      """
      use Ash.Resource,
        domain: #{inspect(storage.domain)},
        #{Recipe.data_layer_option(storage)}
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshWorkflow, AshOban]

      #{Recipe.postgres_block(storage, config.verification)}

      workflow do
        step :submitted do
          transition :begin, to: :verifying
        end

        step :verifying do
          action :verify
          on_success :verified, when: expr(outcome == :passed)
          on_success :rejected, when: expr(outcome == :failed)
          on_error :needs_review

          #{retry(config.max_attempts)}
        end

        step :needs_review do
          transition :approve, to: :verified
          transition :reject, to: :rejected
        end

        step :verified, terminal: true
        step :rejected, terminal: true
      end

      code_interface do
        define :submit, args: [:subject_id]
        define :begin
        define :approve
        define :reject
      end

      actions do
        defaults [:read]

        create :submit do
          accept [:subject_id]
        end

        update :verify do
          require_atomic? false
          accept []
        end
      end

      policies do
        policy action([:approve, :reject]) do
          authorize_if #{inspect(config.can_review)}
        end
      end

      attributes do
        uuid_v7_primary_key :id

        attribute :outcome, :atom do
          constraints one_of: [:passed, :failed]
          public? true
        end

        timestamps()
      end

      relationships do
        #{Recipe.belongs_to(:subject, config.subject, config.key_type)}
      end
      """
    end

    defp retry(1), do: ""

    defp retry(max_attempts) do
      """
      retry do
        max_attempts #{max_attempts}
      end
      """
    end

    defp can_review_contents(config) do
      """
      @moduledoc \"\"\"
      Decides who may approve or reject an `#{inspect(config.verification)}` in review.

      Denies everyone until the application replaces `match?/3`.
      \"\"\"

      use Ash.Policy.SimpleCheck

      @impl true
      def describe(_opts), do: "actor may review this verification"

      @impl true
      def match?(_actor, _context, _opts), do: false
      """
    end
  end
else
  defmodule Mix.Tasks.AshWorkflow.Gen.Verification do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_workflow.gen.verification' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
