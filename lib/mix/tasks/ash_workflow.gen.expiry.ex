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
    gains `has_one :expiry`, an `expired?` calculation and a `:set_expiry`
    update action. When the subject does not exist, it is created with
    `mix ash.gen.resource` first.

    A subject with no expiry never expires. `:set_expiry` creates the
    subject's expiry, or renews the one it has, through the generated
    `Changes.SetExpiry` change. Add that change with an `expires_in:` option to
    another subject action to start the clock there. `--default-expiry` adds it
    to every create of the subject.

    Nobody may create or renew an expiry until the application defines who
    can, in the generated `Checks.CanCreate` and `Checks.CanRenew` modules.

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
      `expires_at`, given as `10s`, `30m`, `12h`, `2d` or `2w`. Without it, no
      `:expiring` step is generated.
    * `--default-expiry` - starts every new subject's expiry this long after
      it is created, given as `10s`, `30m`, `12h`, `2d` or `2w`. The task adds
      `change {Changes.SetExpiry, expires_in: ...}, on: [:create]` to the
      subject's `changes` block. `SetExpiry` creates the expiry with the
      subject create's actor, so `Checks.CanCreate` must let that actor
      through, or the subject create fails. A subject create run with
      `authorize?: false` creates its expiry with `authorize?: false` too.
      Without the flag, nothing is added to the subject's create.
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
    alias Ash.Resource.Igniter, as: ResourceIgniter
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
          default_expiry: :string,
          transition_log: :boolean
        ],
        defaults: [transition_log: true]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      subject = ProjectModule.parse(igniter.args.positional.subject)

      with {:ok, notice_period} <-
             Recipe.parse_duration(options[:notice_period], "--notice-period"),
           {:ok, default_expiry} <-
             Recipe.parse_duration(options[:default_expiry], "--default-expiry") do
        expiry = expiry_module(subject, options[:module])

        config = %{
          subject: subject,
          expiry: expiry,
          can_create: Module.concat([expiry, Checks, CanCreate]),
          can_renew: Module.concat([expiry, Checks, CanRenew]),
          set_expiry: Module.concat([expiry, Changes, SetExpiry]),
          notice_period: notice_period,
          default_expiry: default_expiry,
          transition_log?: options[:transition_log]
        }

        case Recipe.ensure_subject(
               igniter,
               subject,
               options[:domain],
               "expiry",
               []
             ) do
          {:ok, igniter, storage} -> generate_with_key_type(igniter, config, storage)
          {:error, igniter} -> igniter
        end
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp expiry_module(subject, nil), do: Module.concat([inspect(subject) <> "Expiry"])
    defp expiry_module(_subject, module), do: ProjectModule.parse(module)

    # A subject created in this run does not compile yet and gets
    # ash.gen.resource's uuid_v7 key.
    defp generate_with_key_type(igniter, config, storage) do
      case Recipe.key_type(config.subject, "expiry", :uuid_v7) do
        {:ok, key_type} -> generate(igniter, Map.put(config, :key_type, key_type), storage)
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp generate(igniter, config, storage) do
      {exists?, igniter} = ProjectModule.module_exists(igniter, config.expiry)
      {set_expiry_exists?, igniter} = ProjectModule.module_exists(igniter, config.set_expiry)
      {igniter, set_expiry_action?} = defines_set_expiry?(igniter, config.subject)

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
        [expired?: "calculate :expired?, :boolean, expr(expiry.state == :expired || false)"],
        actions: [set_expiry: set_expiry_action(config)],
        interfaces: [set_expiry: "define :set_expiry, args: [:expires_at]"]
      )
      |> then(fn igniter ->
        if exists?, do: igniter, else: create_expiry(igniter, config, storage)
      end)
      |> then(fn igniter ->
        if set_expiry_exists?,
          do: igniter,
          else:
            ProjectModule.create_module(igniter, config.set_expiry, set_expiry_contents(config))
      end)
      |> then(fn igniter ->
        if set_expiry_action?, do: igniter, else: notice_subject_policy(igniter, config)
      end)
      |> add_default_expiry(config)
    end

    defp add_default_expiry(igniter, %{default_expiry: nil}), do: igniter

    defp add_default_expiry(igniter, %{default_expiry: {count, unit}} = config) do
      change =
        "{#{inspect(config.set_expiry)}, expires_in: {#{count}, #{inspect(interval(unit))}}}"

      igniter
      |> Recipe.add_subject_change(config.subject, change, on: [:create])
      |> Igniter.add_notice("""
      Every create of #{inspect(config.subject)} now starts an expiry, through \
      `change #{change}, on: [:create]`. \
      The expiry is created with the subject create's actor, so until \
      #{inspect(config.can_create)} lets that actor through, creating a \
      #{inspect(config.subject)} fails. A create run with `authorize?: false` \
      creates its expiry with `authorize?: false` too.
      """)
    end

    defp defines_set_expiry?(igniter, subject) do
      {exists?, igniter} = ProjectModule.module_exists(igniter, subject)

      if exists?,
        do: ResourceIgniter.defines_action(igniter, subject, :set_expiry),
        else: {igniter, false}
    end

    defp set_expiry_action(config) do
      """
      update :set_expiry do
        argument :expires_at, :utc_datetime_usec, allow_nil?: false
        require_atomic? false
        change #{inspect(config.set_expiry)}
      end
      """
    end

    defp notice_subject_policy(igniter, config) do
      case Spark.Igniter.has_extension(
             igniter,
             config.subject,
             Ash.Resource,
             :authorizers,
             Ash.Policy.Authorizer
           ) do
        {igniter, true} ->
          Igniter.add_notice(igniter, """
          Added :set_expiry to #{inspect(config.subject)}. It uses Ash.Policy.Authorizer, \
          so :set_expiry needs a policy there before anyone can call it, for example:

              policy action(:set_expiry) do
                authorize_if actor_attribute_equals(:role, :account_manager)
              end
          """)

        {igniter, false} ->
          igniter
      end
    end

    defp create_expiry(igniter, config, storage) do
      igniter
      |> ProjectModule.create_module(config.expiry, expiry_contents(config, storage))
      |> ProjectModule.create_module(config.can_create, can_create_contents(config))
      |> ProjectModule.create_module(config.can_renew, can_renew_contents(config))
      |> DomainIgniter.add_resource_reference(storage.domain, config.expiry)
      |> compose_transition_log(config)
      |> Igniter.add_notice("""
      Generated #{inspect(config.expiry)} to expire #{inspect(config.subject)}.

      Nobody can create or renew an expiry yet. Define who may create one in \
      #{inspect(config.can_create)} and who may renew in \
      #{inspect(config.can_renew)}. Both deny everyone as generated.

      A #{inspect(config.subject)} with no expiry never expires. Call \
      #{inspect(config.subject)}.set_expiry/3 to start one, or rerun with \
      --default-expiry to start one on every create.
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
        #{Recipe.create_policy(:create, config.can_create)}

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
        #{Recipe.belongs_to(:subject, config.subject, config.key_type)}
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

    defp interval(:seconds), do: :second
    defp interval(:minutes), do: :minute
    defp interval(:hours), do: :hour
    defp interval(:days), do: :day

    defp set_expiry_contents(config) do
      ~S'''
      @moduledoc """
      Starts or renews the subject's expiry once a subject action succeeds.

      `expires_at` is the action's `:expires_at` argument, or else now plus the
      `expires_in:` option, such as `{30, :day}`, in `:second`, `:minute`,
      `:hour`, `:day` or `:week`. The actor and tenant pass through to
      `EXPIRY.create/3` and `EXPIRY.renew/3`, so `Checks.CanCreate` and
      `Checks.CanRenew` still decide.
      """

      use Ash.Resource.Change

      require Ash.Query

      alias EXPIRY

      @units [:second, :minute, :hour, :day, :week]

      @impl true
      def init(opts) do
        case Keyword.fetch(opts, :expires_in) do
          :error ->
            {:ok, opts}

          {:ok, {count, unit}} when is_integer(count) and count > 0 and unit in @units ->
            {:ok, opts}

          {:ok, expires_in} ->
            {:error,
             "expires_in must be {count, unit} with a positive count and a unit in " <>
               "#{inspect(@units)}, got: #{inspect(expires_in)}"}
        end
      end

      @impl true
      def change(changeset, opts, context) do
        case expires_at(changeset, opts[:expires_in]) do
          {:ok, expires_at} ->
            Ash.Changeset.after_action(changeset, fn _changeset, subject ->
              with {:ok, _expiry} <- set_expiry(subject, expires_at, context) do
                {:ok, subject}
              end
            end)

          :error ->
            Ash.Changeset.add_error(
              changeset,
              Ash.Error.Changes.InvalidChanges.exception(
                fields: [:expires_at],
                message:
                  "needs an :expires_at argument or an expires_in: option on " <>
                    "#{inspect(__MODULE__)} to know when the expiry ends"
              )
            )
        end
      end

      @impl true
      def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

      defp expires_at(changeset, expires_in) do
        case Ash.Changeset.fetch_argument(changeset, :expires_at) do
          {:ok, %DateTime{} = expires_at} -> {:ok, expires_at}
          _missing -> from_now(expires_in)
        end
      end

      defp from_now(nil), do: :error
      defp from_now({count, :week}), do: from_now({count * 7, :day})
      defp from_now({count, unit}), do: {:ok, DateTime.add(DateTime.utc_now(), count, unit)}

      defp set_expiry(subject, expires_at, context) do
        opts = Ash.Context.to_opts(context)

        # Read without the actor: whether an expiry exists decides between
        # create and renew, and each of those is authorized on its own.
        EXPIRY_ALIAS
        |> Ash.Query.filter(subject_id == ^subject.id)
        |> Ash.read_one(Keyword.merge(opts, authorize?: false))
        |> case do
          {:ok, nil} -> EXPIRY_ALIAS.create(subject.id, expires_at, opts)
          {:ok, expiry} -> EXPIRY_ALIAS.renew(expiry, expires_at, opts)
          {:error, error} -> {:error, error}
        end
      end
      '''
      |> String.replace("EXPIRY_ALIAS", config.expiry |> Module.split() |> List.last())
      |> String.replace("EXPIRY", inspect(config.expiry))
    end

    defp can_create_contents(config) do
      Recipe.deny_check_contents(
        "Decides who may create an `#{inspect(config.expiry)}` for a subject.",
        "actor may create an expiry for this subject"
      )
    end

    defp can_renew_contents(config) do
      Recipe.deny_check_contents(
        "Decides who may renew an `#{inspect(config.expiry)}`.",
        "actor may renew this expiry"
      )
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
