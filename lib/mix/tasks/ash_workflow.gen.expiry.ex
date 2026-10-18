defmodule Mix.Tasks.AshWorkflow.Gen.Expiry.Docs do
  @moduledoc false

  def short_doc do
    "Adds an expiry workflow to a resource"
  end

  def example do
    "mix ash_workflow.gen.expiry MyApp.Contracts.Contract --notice-period 30d"
  end

  def long_doc do
    """
    #{short_doc()}

    Generates an expiry resource that moves to `:expired` once its
    `expires_at` passes, and back to `:active` when it is renewed. The subject
    gains `has_one :expiry` and an `expired?` calculation. When the subject
    does not exist, it is created with `mix ash.gen.resource` first.

    Nobody may renew until the application defines who can, in the generated
    `Checks.CanRenew` module.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--module` - the expiry resource's module name. Defaults to the
      subject's name with `Expiry` appended.
    * `--domain` - the domain for a subject the task creates. Required only
      when the subject does not exist.
    * `--notice-period` - moves an expiry to `:expiring` this long before
      `expires_at`, given as `30m`, `12h`, `2d` or `2w`. Without it, no
      `:expiring` step is generated.
    * `--transition-log` - also generates a transition log for the expiry
      with `mix ash_workflow.gen.transition_log`. Defaults to `true`.
    """
  end
end

# Guarded on the struct this task builds rather than on `Igniter` itself. See
# `Mix.Tasks.AshWorkflow.Gen.TransitionLog` for why.
if Code.ensure_loaded?(Igniter.Mix.Task.Info) do
  defmodule Mix.Tasks.AshWorkflow.Gen.Expiry do
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
          notice_period: :string,
          transition_log: :boolean
        ],
        defaults: [transition_log: true]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      subject = ProjectModule.parse(igniter.args.positional.subject)

      case Recipe.parse_duration(options[:notice_period], "--notice-period") do
        {:ok, notice_period} ->
          expiry = expiry_module(subject, options[:module])

          config = %{
            subject: subject,
            expiry: expiry,
            can_renew: Module.concat([expiry, Checks, CanRenew]),
            notice_period: notice_period,
            transition_log?: options[:transition_log]
          }

          case Recipe.ensure_subject(
                 igniter,
                 subject,
                 options[:domain],
                 "expiry",
                 []
               ) do
            {:ok, igniter, storage} -> generate(igniter, config, storage)
            {:error, igniter} -> igniter
          end

        {:error, message} ->
          Igniter.add_issue(igniter, message)
      end
    end

    defp expiry_module(subject, nil), do: Module.concat([inspect(subject) <> "Expiry"])
    defp expiry_module(_subject, module), do: ProjectModule.parse(module)

    defp generate(igniter, config, storage) do
      {exists?, igniter} = ProjectModule.module_exists(igniter, config.expiry)

      igniter
      |> Recipe.add_subject_edits(
        config.subject,
        [
          expiry: """
          has_one :expiry, #{inspect(config.expiry)} do
            destination_attribute :subject_id
            public? true
          end
          """
        ],
        expired?: "calculate :expired?, :boolean, expr(expiry.state == :expired)"
      )
      |> then(fn igniter ->
        if exists?, do: igniter, else: create_expiry(igniter, config, storage)
      end)
    end

    defp create_expiry(igniter, config, storage) do
      igniter
      |> ProjectModule.create_module(config.expiry, expiry_contents(config, storage))
      |> ProjectModule.create_module(config.can_renew, can_renew_contents(config))
      |> DomainIgniter.add_resource_reference(storage.domain, config.expiry)
      |> compose_transition_log(config)
      |> Igniter.add_notice("""
      Generated #{inspect(config.expiry)} to expire #{inspect(config.subject)}.

      Nobody can renew an expiry yet. Define who may renew in \
      #{inspect(config.can_renew)}, which denies everyone as generated.
      """)
    end

    defp compose_transition_log(igniter, %{transition_log?: false}), do: igniter

    defp compose_transition_log(igniter, config),
      do: Recipe.compose_transition_log(igniter, config.expiry, nil)

    defp expiry_contents(config, storage) do
      """
      use Ash.Resource,
        domain: #{inspect(storage.domain)},
        #{Recipe.data_layer_option(storage)}
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshWorkflow, AshOban]

      #{Recipe.postgres_block(storage, config.expiry, Recipe.identity_index_name(config.expiry, :unique_subject))}

      workflow do
        #{steps(config.notice_period)}
      end

      code_interface do
        define :create, args: [:subject_id, :expires_at]
        define :renew, args: [:expires_at]
      end

      actions do
        defaults [:read]

        create :create do
          accept [:subject_id, :expires_at]
        end

        update :renew do
          require_atomic? false
          argument :expires_at, :utc_datetime_usec, allow_nil?: false
          change set_attribute(:expires_at, arg(:expires_at))
        end
      end

      policies do
        policy action(:renew) do
          authorize_if #{inspect(config.can_renew)}
        end
      end

      attributes do
        uuid_v7_primary_key :id
        attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
        timestamps()
      end

      relationships do
        belongs_to :subject, #{inspect(config.subject)}, allow_nil?: false, public?: true
      end

      #{expiring_at(config.notice_period)}

      identities do
        identity :unique_subject, [:subject_id]#{Recipe.pre_check_with(storage)}
      end
      """
    end

    defp steps(nil) do
      """
      step :active do
        transition :renew, to: :active

        #{expired_timeout()}
      end

      #{expired_step()}
      """
    end

    defp steps(_notice_period) do
      """
      step :active do
        transition :renew, to: :active

        timeout :expiring do
          fire_at :expiring_at
          transition_to :expiring
        end
      end

      step :expiring do
        transition :renew, to: :active

        #{expired_timeout()}
      end

      #{expired_step()}
      """
    end

    defp expired_timeout do
      """
      timeout :expired do
        fire_at :expires_at
        transition_to :expired
      end
      """
    end

    defp expired_step do
      """
      step :expired do
        transition :renew, to: :active
      end
      """
    end

    defp expiring_at(nil), do: ""

    defp expiring_at({count, unit}) do
      """
      calculations do
        calculate :expiring_at, :utc_datetime_usec, expr(datetime_add(expires_at, #{-count}, #{inspect(interval(unit))}))
      end
      """
    end

    defp interval(:minutes), do: :minute
    defp interval(:hours), do: :hour
    defp interval(:days), do: :day

    defp can_renew_contents(config) do
      """
      @moduledoc \"\"\"
      Decides who may renew an `#{inspect(config.expiry)}`.

      Denies everyone until the application replaces `match?/3`.
      \"\"\"

      use Ash.Policy.SimpleCheck

      @impl true
      def describe(_opts), do: "actor may renew this expiry"

      @impl true
      def match?(_actor, _context, _opts), do: false
      """
    end
  end
else
  defmodule Mix.Tasks.AshWorkflow.Gen.Expiry do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_workflow.gen.expiry' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
