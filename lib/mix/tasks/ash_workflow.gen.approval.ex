defmodule Mix.Tasks.AshWorkflow.Gen.Approval.Docs do
  @moduledoc false

  def short_doc do
    "Adds an approval workflow to a resource"
  end

  def example do
    "mix ash_workflow.gen.approval MyApp.Expenses.Expense --approver MyApp.Accounts.User --overdue-after 2d"
  end

  def long_doc do
    """
    #{short_doc()}

    Generates an approval resource that runs the approval workflow for the
    subject resource, and a decision resource with one row per approver.
    The subject gains `has_many :approvals`, `has_one :latest_approval` and an
    `approved?` calculation. When the subject does not exist, it is created
    with `mix ash.gen.resource` first.

    Nobody may open a request or approve until the application defines who
    can, in the generated `Checks.CanRequest` and `Checks.CanApprove` modules.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--approver` - required. The actor resource. Decisions and the requester
      belong to it.
    * `--module` - the approval resource's module name. Defaults to the
      subject's name with `Approval` appended.
    * `--domain` - the domain for a subject the task creates. Required only
      when the subject does not exist.
    * `--required-approvals` - the number of approvals a request
      needs. Defaults to `1`.
    * `--overdue-after` - moves a request nobody has decided to `:overdue`
      after this long, given as `30m`, `12h`, `2d` or `2w`. Without it, no
      `:overdue` step is generated.
    * `--transition-log` - also generates a transition log for the approval
      with `mix ash_workflow.gen.transition_log`. Defaults to `true`.
    """
  end
end

# Guarded on the struct this task builds rather than on `Igniter` itself. See
# `Mix.Tasks.AshWorkflow.Gen.TransitionLog` for why.
if Code.ensure_loaded?(Igniter.Mix.Task.Info) do
  defmodule Mix.Tasks.AshWorkflow.Gen.Approval do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"
    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Ash.Domain.Igniter, as: DomainIgniter
    alias Ash.Resource.Igniter, as: ResourceIgniter
    alias Igniter.Project.Module, as: ProjectModule

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example: __MODULE__.Docs.example(),
        positional: [:subject],
        composes: ["ash.gen.resource", "ash_workflow.gen.transition_log"],
        schema: [
          approver: :string,
          module: :string,
          domain: :string,
          required_approvals: :integer,
          overdue_after: :string,
          transition_log: :boolean
        ],
        defaults: [required_approvals: 1, transition_log: true],
        required: [:approver]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      subject = ProjectModule.parse(igniter.args.positional.subject)

      with {:ok, overdue_after} <- parse_duration(options[:overdue_after]),
           :ok <- validate_required_approvals(options[:required_approvals]) do
        approval = approval_module(subject, options[:module])

        names = %{
          subject: subject,
          approver: ProjectModule.parse(options[:approver]),
          approval: approval,
          decision: Module.concat([inspect(approval) <> "Decision"]),
          can_request: Module.concat([approval, Checks, CanRequest]),
          can_approve: Module.concat([approval, Checks, CanApprove]),
          record_decision: Module.concat([approval, Changes, RecordDecision])
        }

        config = %{
          names: names,
          required_approvals: options[:required_approvals],
          overdue_after: overdue_after,
          transition_log?: options[:transition_log]
        }

        {exists?, igniter} = ProjectModule.module_exists(igniter, subject)

        if exists?,
          do: existing_subject(igniter, config),
          else: missing_subject(igniter, config, options[:domain])
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp parse_duration(nil), do: {:ok, nil}

    defp parse_duration(value) do
      case Regex.run(~r/^([1-9]\d*)([mhdw])$/, value) do
        [_match, count, unit] -> {:ok, duration(String.to_integer(count), unit)}
        nil -> {:error, "--overdue-after must look like 30m, 12h, 2d or 2w, got: #{value}"}
      end
    end

    defp duration(count, "m"), do: {count, :minutes}
    defp duration(count, "h"), do: {count, :hours}
    defp duration(count, "d"), do: {count, :days}
    defp duration(count, "w"), do: {count * 7, :days}

    defp validate_required_approvals(count) when count >= 1, do: :ok

    defp validate_required_approvals(count),
      do: {:error, "--required-approvals must be at least 1, got: #{count}"}

    defp approval_module(subject, nil), do: Module.concat([inspect(subject) <> "Approval"])
    defp approval_module(_subject, module), do: ProjectModule.parse(module)

    defp existing_subject(igniter, config) do
      subject = config.names.subject

      case Code.ensure_compiled(subject) do
        {:module, _module} ->
          storage = storage(subject, Ash.Resource.Info.domain(subject))
          generate(igniter, config, storage)

        {:error, reason} ->
          Igniter.add_issue(
            igniter,
            "Could not load #{inspect(subject)} (#{inspect(reason)}). " <>
              "An existing subject must compile before adding approval to it."
          )
      end
    end

    defp missing_subject(igniter, config, nil) do
      Igniter.add_issue(
        igniter,
        "#{inspect(config.names.subject)} does not exist. Pass --domain to create it."
      )
    end

    # A created subject stores its records the same way the approver does.
    defp missing_subject(igniter, config, domain) do
      domain = ProjectModule.parse(domain)
      approver = config.names.approver

      storage =
        case Code.ensure_compiled(approver) do
          {:module, _module} -> storage(approver, domain)
          {:error, _reason} -> %{domain: domain, data_layer: nil, repo: nil}
        end

      igniter
      |> Igniter.compose_task(
        "ash.gen.resource",
        [
          inspect(config.names.subject),
          "--uuid-v7-primary-key",
          "id",
          "--timestamps",
          "--default-actions",
          "read,create,update,destroy",
          "--domain",
          inspect(domain)
        ] ++ extend_flag(storage.data_layer)
      )
      |> generate(config, storage)
    end

    defp storage(resource, domain) do
      data_layer = Ash.Resource.Info.data_layer(resource)
      %{domain: domain, data_layer: data_layer, repo: repo(resource, data_layer)}
    end

    defp repo(resource, AshPostgres.DataLayer) do
      # Resolved at runtime: ash_postgres is a dev/test-only dependency of this
      # library, so referencing it directly warns in every consuming project.
      Module.concat(["AshPostgres", "DataLayer", "Info"]).repo(resource)
    end

    defp repo(_resource, _data_layer), do: nil

    defp extend_flag(Ash.DataLayer.Ets), do: ["--extend", "ets"]
    defp extend_flag(AshPostgres.DataLayer), do: ["--extend", "postgres"]
    defp extend_flag(_data_layer), do: []

    defp generate(igniter, config, storage) do
      names = config.names
      {exists?, igniter} = ProjectModule.module_exists(igniter, names.approval)

      igniter
      |> add_subject_relationships(names)
      |> then(fn igniter ->
        if exists?, do: igniter, else: create_approval(igniter, config, storage)
      end)
    end

    defp add_subject_relationships(igniter, names) do
      igniter
      |> ResourceIgniter.add_new_relationship(names.subject, :approvals, """
      has_many :approvals, #{inspect(names.approval)} do
        destination_attribute :subject_id
        public? true
      end
      """)
      |> ResourceIgniter.add_new_relationship(names.subject, :latest_approval, """
      has_one :latest_approval, #{inspect(names.approval)} do
        destination_attribute :subject_id
        from_many? true
        sort inserted_at: :desc
        public? true
      end
      """)
      |> ResourceIgniter.add_new_calculation(
        names.subject,
        :approved?,
        "calculate :approved?, :boolean, expr(latest_approval.state == :approved)"
      )
    end

    defp create_approval(igniter, config, storage) do
      names = config.names

      igniter
      |> ProjectModule.create_module(names.approval, approval_contents(config, storage))
      |> ProjectModule.create_module(names.decision, decision_contents(names, storage))
      |> ProjectModule.create_module(names.record_decision, record_decision_contents(names))
      |> ProjectModule.create_module(names.can_request, can_request_contents(names))
      |> ProjectModule.create_module(names.can_approve, can_approve_contents(names))
      |> DomainIgniter.add_resource_reference(storage.domain, names.approval)
      |> DomainIgniter.add_resource_reference(storage.domain, names.decision)
      |> compose_transition_log(names, config.transition_log?)
      |> Igniter.add_notice("""
      Generated #{inspect(names.approval)} to approve #{inspect(names.subject)}.

      Nobody can open or approve a request yet. Define who may open one in \
      #{inspect(names.can_request)} and who may approve in \
      #{inspect(names.can_approve)}. Both deny everyone as generated.
      """)
    end

    defp compose_transition_log(igniter, _names, false), do: igniter

    defp compose_transition_log(igniter, names, true) do
      Igniter.compose_task(igniter, "ash_workflow.gen.transition_log", [
        inspect(names.approval),
        "--actor",
        inspect(names.approver)
      ])
    end

    defp approval_contents(config, storage) do
      names = config.names

      """
      use Ash.Resource,
        domain: #{inspect(storage.domain)},
        #{data_layer_option(storage)}
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshWorkflow, AshOban]

      #{postgres_block(storage, names.approval)}

      workflow do
        step :pending do
          #{decision_transitions(:pending)}

          #{overdue_timeout(config.overdue_after)}
        end

        #{overdue_step(config.overdue_after)}

        step :approved, terminal: true
        step :rejected, terminal: true
        step :cancelled, terminal: true
      end

      code_interface do
        define :request, args: [:subject_id]
        define :approve
        define :reject
        define :cancel
      end

      actions do
        defaults [:read]

        create :request do
          accept [:subject_id]
          change relate_actor(:requested_by)
          change set_attribute(:requested_at, &DateTime.utc_now/0)
        end

        update :approve do
          require_atomic? false
          argument :comment, :string
          change {#{inspect(names.record_decision)}, decision: :approved}
        end

        update :reject do
          require_atomic? false
          argument :comment, :string
          change {#{inspect(names.record_decision)}, decision: :rejected}
        end
      end

      policies do
        policy action(:request) do
          authorize_if #{inspect(names.can_request)}
        end

        policy action([:approve, :reject]) do
          forbid_if expr(requested_by_id == ^actor(:id))
          forbid_if expr(exists(decisions, approver_id == ^actor(:id)))
          authorize_if #{inspect(names.can_approve)}
        end

        policy action(:cancel) do
          authorize_if relates_to_actor_via(:requested_by)
        end
      end

      attributes do
        uuid_v7_primary_key :id

        attribute :required_approvals, :integer do
          allow_nil? false
          default #{config.required_approvals}
          constraints min: 1
          public? true
        end

        attribute :requested_at, :utc_datetime_usec, allow_nil?: false, public?: true

        timestamps()
      end

      relationships do
        belongs_to :subject, #{inspect(names.subject)}, allow_nil?: false, public?: true
        belongs_to :requested_by, #{inspect(names.approver)}, allow_nil?: false, public?: true

        has_many :decisions, #{inspect(names.decision)} do
          destination_attribute :approval_id
          public? true
        end
      end

      aggregates do
        count :approval_count, :decisions do
          filter expr(decision == :approved)
        end
      end

      calculations do
        calculate :approvals_remaining, :integer, expr(required_approvals - approval_count)
      end
      """
    end

    defp decision_transitions(step) do
      """
      transition :approve do
        route :approved, when: expr(approvals_remaining <= 1)
        route #{inspect(step)}, when: expr(approvals_remaining > 1)
      end

      transition :reject, to: :rejected
      transition :cancel, to: :cancelled
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
        #{decision_transitions(:overdue)}
      end
      """
    end

    defp decision_contents(names, storage) do
      """
      use Ash.Resource,
        domain: #{inspect(storage.domain)},
        #{data_layer_option(storage)}
        authorizers: [Ash.Policy.Authorizer]

      #{postgres_block(storage, names.decision, identity_index_name(names.decision))}

      actions do
        defaults [:read]

        create :create do
          accept [:approval_id, :decision, :comment]
          change relate_actor(:approver)
          change set_attribute(:decided_at, &DateTime.utc_now/0)
        end
      end

      # Decisions are created only by the approval's :approve and :reject
      # actions, which skip authorization for it.
      policies do
        policy action_type(:read) do
          authorize_if always()
        end
      end

      attributes do
        uuid_v7_primary_key :id

        attribute :decision, :atom do
          allow_nil? false
          constraints one_of: [:approved, :rejected]
          public? true
        end

        attribute :comment, :string, public?: true
        attribute :decided_at, :utc_datetime_usec, allow_nil?: false, public?: true
      end

      relationships do
        belongs_to :approval, #{inspect(names.approval)}, allow_nil?: false, public?: true
        belongs_to :approver, #{inspect(names.approver)}, allow_nil?: false, public?: true
      end

      identities do
        identity :unique_approver, [:approval_id, :approver_id]#{pre_check_with(storage)}
      end
      """
    end

    defp record_decision_contents(names) do
      """
      @moduledoc "Records the actor's decision on the approval being updated."

      use Ash.Resource.Change

      @impl true
      def change(changeset, opts, context) do
        Ash.Changeset.after_action(changeset, fn changeset, approval ->
          #{inspect(names.decision)}
          |> Ash.Changeset.for_create(
            :create,
            %{
              approval_id: approval.id,
              decision: opts[:decision],
              comment: Ash.Changeset.get_argument(changeset, :comment)
            },
            actor: context.actor,
            authorize?: false
          )
          |> Ash.create()
          |> case do
            {:ok, _decision} -> {:ok, approval}
            {:error, error} -> {:error, error}
          end
        end)
      end
      """
    end

    defp can_request_contents(names) do
      """
      @moduledoc \"\"\"
      Decides who may open an `#{inspect(names.approval)}` on a subject.

      Denies everyone until the application replaces `match?/3`.
      \"\"\"

      use Ash.Policy.SimpleCheck

      @impl true
      def describe(_opts), do: "actor may request approval of this subject"

      @impl true
      def match?(_actor, _context, _opts), do: false
      """
    end

    defp can_approve_contents(names) do
      """
      @moduledoc \"\"\"
      Decides who may approve or reject an `#{inspect(names.approval)}`.

      Denies everyone until the application replaces `match?/3`.
      \"\"\"

      use Ash.Policy.SimpleCheck

      @impl true
      def describe(_opts), do: "actor may decide this approval"

      @impl true
      def match?(_actor, _context, _opts), do: false
      """
    end

    defp pre_check_with(%{data_layer: AshPostgres.DataLayer}), do: ""
    defp pre_check_with(storage), do: ", pre_check_with: #{inspect(storage.domain)}"

    defp data_layer_option(%{data_layer: nil}), do: ""
    defp data_layer_option(%{data_layer: data_layer}), do: "data_layer: #{inspect(data_layer)},"

    defp postgres_block(storage, module, extra \\ "")

    defp postgres_block(%{data_layer: AshPostgres.DataLayer, repo: repo}, module, extra) do
      """
      postgres do
        table #{inspect(table_name(module))}
        repo #{inspect(repo)}
        #{extra}
      end
      """
    end

    defp postgres_block(_storage, _module, _extra), do: ""

    # Postgres truncates identifiers past 63 bytes, and AshPostgres rejects an
    # identity whose default index name would be truncated.
    defp identity_index_name(decision) do
      suffix = "_unique_approver_index"
      table = table_name(decision)
      max_table_bytes = 63 - byte_size(suffix)

      if byte_size(table) > max_table_bytes do
        name = binary_part(table, 0, max_table_bytes) <> suffix
        "identity_index_names unique_approver: #{inspect(name)}"
      else
        ""
      end
    end

    defp table_name(module) do
      module |> Module.split() |> List.last() |> Macro.underscore() |> Kernel.<>("s")
    end
  end
else
  defmodule Mix.Tasks.AshWorkflow.Gen.Approval do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_workflow.gen.approval' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
