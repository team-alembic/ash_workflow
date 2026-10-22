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
      after this long, given as `10s`, `30m`, `12h`, `2d` or `2w`. Without
      it, no `:overdue` step is generated.
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

      with {:ok, overdue_after} <-
             Recipe.parse_duration(options[:overdue_after], "--overdue-after"),
           :ok <- validate_required_approvals(options[:required_approvals]) do
        approval = approval_module(subject, options[:module])
        approver = ProjectModule.parse(options[:approver])

        names = %{
          subject: subject,
          approver: approver,
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

        # A created subject stores its records the same way the approver does.
        case Recipe.ensure_subject(
               igniter,
               subject,
               options[:domain],
               "approval",
               [approver]
             ) do
          {:ok, igniter, storage} -> generate_with_key_types(igniter, config, storage)
          {:error, igniter} -> igniter
        end
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp validate_required_approvals(count) when count >= 1, do: :ok

    defp validate_required_approvals(count),
      do: {:error, "--required-approvals must be at least 1, got: #{count}"}

    defp approval_module(subject, nil), do: Module.concat([inspect(subject) <> "Approval"])
    defp approval_module(_subject, module), do: ProjectModule.parse(module)

    # The approval's foreign keys take the type of the key they point at, so a
    # subject or approver with an integer key gets an integer column. A subject
    # created in this run does not compile yet and gets ash.gen.resource's
    # uuid_v7 key.
    defp generate_with_key_types(igniter, config, storage) do
      with {:ok, subject_type} <- Recipe.key_type(config.names.subject, "approval", :uuid_v7),
           {:ok, approver_type} <- Recipe.key_type(config.names.approver, "approval", nil) do
        key_types = %{subject: subject_type, approver: approver_type}
        generate(igniter, Map.put(config, :key_types, key_types), storage)
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp generate(igniter, config, storage) do
      names = config.names
      {exists?, igniter} = ProjectModule.module_exists(igniter, names.approval)

      igniter
      |> Recipe.add_subject_edits(
        names.subject,
        [
          approvals: """
          has_many :approvals, #{inspect(names.approval)} do
            destination_attribute :subject_id
            public? true
          end
          """,
          latest_approval: """
          has_one :latest_approval, #{inspect(names.approval)} do
            destination_attribute :subject_id
            from_many? true
            sort inserted_at: :desc
            public? true
          end
          """
        ],
        approved?:
          "calculate :approved?, :boolean, expr(latest_approval.state == :approved || false)"
      )
      |> then(fn igniter ->
        if exists?, do: igniter, else: create_approval(igniter, config, storage)
      end)
    end

    defp create_approval(igniter, config, storage) do
      names = config.names

      igniter
      |> ProjectModule.create_module(names.approval, approval_contents(config, storage))
      |> ProjectModule.create_module(
        names.decision,
        decision_contents(names, storage, config.key_types.approver)
      )
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

    defp compose_transition_log(igniter, names, true),
      do: Recipe.compose_transition_log(igniter, names.approval, names.approver)

    # Two approvals of one request would otherwise both count the decisions
    # before either writes its own, and both loop back to the current step.
    # The lock's before_action runs ahead of the route's, which then reads
    # approvals_remaining from the locked row.
    defp approval_contents(config, storage) do
      names = config.names

      """
      use Ash.Resource,
        domain: #{inspect(storage.domain)},
        #{Recipe.data_layer_option(storage)}
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshWorkflow, AshOban]

      #{Recipe.postgres_block(storage, names.approval)}

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
          #{Recipe.lock_for_update(storage)}change {#{inspect(names.record_decision)}, decision: :approved}
        end

        update :reject do
          require_atomic? false
          argument :comment, :string
          #{Recipe.lock_for_update(storage)}change {#{inspect(names.record_decision)}, decision: :rejected}
        end
      end

      policies do
        #{Recipe.create_policy(:request, names.can_request)}

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
        #{Recipe.belongs_to(:subject, names.subject, config.key_types.subject)}
        #{Recipe.belongs_to(:requested_by, names.approver, config.key_types.approver)}

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

    defp decision_contents(names, storage, approver_key_type) do
      """
      use Ash.Resource,
        domain: #{inspect(storage.domain)},
        #{Recipe.data_layer_option(storage)}
        authorizers: [Ash.Policy.Authorizer]

      #{Recipe.postgres_block(storage, names.decision, Recipe.identity_index_name(names.decision, :unique_approver))}

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
        #{Recipe.belongs_to(:approval, names.approval, nil)}
        #{Recipe.belongs_to(:approver, names.approver, approver_key_type)}
      end

      identities do
        identity :unique_approver, [:approval_id, :approver_id]#{Recipe.pre_check_with(storage)}
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
      Recipe.deny_check_contents(
        "Decides who may open an `#{inspect(names.approval)}` on a subject.",
        "actor may request approval of this subject"
      )
    end

    defp can_approve_contents(names) do
      Recipe.deny_check_contents(
        "Decides who may approve or reject an `#{inspect(names.approval)}`.",
        "actor may decide this approval"
      )
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
