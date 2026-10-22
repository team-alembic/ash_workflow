defmodule Mix.Tasks.AshWorkflow.Gen.Review.Docs do
  @moduledoc false

  def short_doc do
    "Adds a review workflow to a resource"
  end

  def example do
    "mix ash_workflow.gen.review MyApp.Content.Article --reviewer MyApp.Accounts.User --overdue-after 3d"
  end

  def long_doc do
    """
    #{short_doc()}

    Generates a review resource that runs the review workflow for the subject
    resource, and a decision resource with one row per review round. A
    reviewer approves, rejects or requests changes, and the requester
    resubmits after changes are requested. The subject gains
    `has_many :reviews`, `has_one :latest_review` and a `review_approved?`
    calculation. When the subject does not exist, it is created with
    `mix ash.gen.resource` first.

    Nobody may request or review until the application defines who can, in
    the generated `Checks.CanRequest` and `Checks.CanReview` modules.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--reviewer` - required. The actor resource. Decisions and the
      requester belong to it.
    * `--module` - the review resource's module name. Defaults to the
      subject's name with `Review` appended.
    * `--domain` - the domain for a subject the task creates. Required only
      when the subject does not exist.
    * `--overdue-after` - moves a review the reviewer has not decided to
      `:overdue` this long after it was last submitted, given as `10s`,
      `30m`, `12h`, `2d` or `2w`. Without it, no `:overdue` step is generated.
    * `--transition-log` - also generates a transition log for the review
      with `mix ash_workflow.gen.transition_log`. Defaults to `true`.
    """
  end
end

# Guarded on the struct this task builds rather than on `Igniter` itself. See
# `Mix.Tasks.AshWorkflow.Gen.TransitionLog` for why.
if Code.ensure_loaded?(Igniter.Mix.Task.Info) do
  defmodule Mix.Tasks.AshWorkflow.Gen.Review do
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
          reviewer: :string,
          module: :string,
          domain: :string,
          overdue_after: :string,
          transition_log: :boolean
        ],
        defaults: [transition_log: true],
        required: [:reviewer]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      subject = ProjectModule.parse(igniter.args.positional.subject)

      case Recipe.parse_duration(options[:overdue_after], "--overdue-after") do
        {:ok, overdue_after} ->
          review = review_module(subject, options[:module])
          reviewer = ProjectModule.parse(options[:reviewer])

          names = %{
            subject: subject,
            reviewer: reviewer,
            review: review,
            decision: Module.concat([inspect(review) <> "Decision"]),
            can_request: Module.concat([review, Checks, CanRequest]),
            can_review: Module.concat([review, Checks, CanReview]),
            record_decision: Module.concat([review, Changes, RecordDecision])
          }

          config = %{
            names: names,
            overdue_after: overdue_after,
            transition_log?: options[:transition_log]
          }

          # A created subject stores its records the same way the reviewer does.
          case Recipe.ensure_subject(
                 igniter,
                 subject,
                 options[:domain],
                 "review",
                 [reviewer]
               ) do
            {:ok, igniter, storage} -> generate_with_key_types(igniter, config, storage)
            {:error, igniter} -> igniter
          end

        {:error, message} ->
          Igniter.add_issue(igniter, message)
      end
    end

    defp review_module(subject, nil), do: Module.concat([inspect(subject) <> "Review"])
    defp review_module(_subject, module), do: ProjectModule.parse(module)

    # The review's foreign keys take the type of the key they point at. A
    # subject created in this run does not compile yet and gets
    # ash.gen.resource's uuid_v7 key.
    defp generate_with_key_types(igniter, config, storage) do
      with {:ok, subject_type} <- Recipe.key_type(config.names.subject, "review", :uuid_v7),
           {:ok, reviewer_type} <- Recipe.key_type(config.names.reviewer, "review", nil) do
        key_types = %{subject: subject_type, reviewer: reviewer_type}
        generate(igniter, Map.put(config, :key_types, key_types), storage)
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp generate(igniter, config, storage) do
      names = config.names
      {exists?, igniter} = ProjectModule.module_exists(igniter, names.review)

      igniter
      |> Recipe.add_subject_edits(
        names.subject,
        [
          reviews: """
          has_many :reviews, #{inspect(names.review)} do
            destination_attribute :subject_id
            public? true
          end
          """,
          latest_review: """
          has_one :latest_review, #{inspect(names.review)} do
            destination_attribute :subject_id
            from_many? true
            sort inserted_at: :desc
            public? true
          end
          """
        ],
        review_approved?:
          "calculate :review_approved?, :boolean, expr(latest_review.state == :approved || false)"
      )
      |> then(fn igniter ->
        if exists?, do: igniter, else: create_review(igniter, config, storage)
      end)
    end

    defp create_review(igniter, config, storage) do
      names = config.names

      igniter
      |> ProjectModule.create_module(names.review, review_contents(config, storage))
      |> ProjectModule.create_module(
        names.decision,
        decision_contents(names, storage, config.key_types.reviewer)
      )
      |> ProjectModule.create_module(names.record_decision, record_decision_contents(names))
      |> ProjectModule.create_module(names.can_request, can_request_contents(names))
      |> ProjectModule.create_module(names.can_review, can_review_contents(names))
      |> DomainIgniter.add_resource_reference(storage.domain, names.review)
      |> DomainIgniter.add_resource_reference(storage.domain, names.decision)
      |> compose_transition_log(names, config.transition_log?)
      |> Igniter.add_notice("""
      Generated #{inspect(names.review)} to review #{inspect(names.subject)}.

      Nobody can request or review yet. Define who may open a review in \
      #{inspect(names.can_request)} and who may review in \
      #{inspect(names.can_review)}. Both deny everyone as generated.
      """)
    end

    defp compose_transition_log(igniter, _names, false), do: igniter

    defp compose_transition_log(igniter, names, true),
      do: Recipe.compose_transition_log(igniter, names.review, names.reviewer)

    defp review_contents(config, storage) do
      names = config.names

      """
      use Ash.Resource,
        domain: #{inspect(storage.domain)},
        #{Recipe.data_layer_option(storage)}
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshWorkflow, AshOban]

      #{Recipe.postgres_block(storage, names.review)}

      workflow do
        step :in_review do
          #{decision_transitions()}

          #{overdue_timeout(config.overdue_after)}
        end

        #{overdue_step(config.overdue_after)}

        step :changes_requested do
          transition :resubmit, to: :in_review
        end

        step :approved, terminal: true
        step :rejected, terminal: true
      end

      code_interface do
        define :request, args: [:subject_id]
        define :request_changes, args: [:comment]
        define :approve
        define :reject
        define :resubmit
      end

      actions do
        defaults [:read]

        create :request do
          accept [:subject_id]
          change relate_actor(:requested_by)
          change set_attribute(:submitted_at, &DateTime.utc_now/0)
        end

        update :request_changes do
          require_atomic? false
          argument :comment, :string, allow_nil?: false
          change {#{inspect(names.record_decision)}, decision: :changes_requested}
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

        update :resubmit do
          require_atomic? false
          change atomic_update(:round, expr(round + 1))
          change set_attribute(:submitted_at, &DateTime.utc_now/0)
        end
      end

      policies do
        #{Recipe.create_policy(:request, names.can_request)}

        policy action([:request_changes, :approve, :reject]) do
          forbid_if expr(requested_by_id == ^actor(:id))
          authorize_if #{inspect(names.can_review)}
        end

        policy action(:resubmit) do
          authorize_if relates_to_actor_via(:requested_by)
        end
      end

      attributes do
        uuid_v7_primary_key :id
        attribute :round, :integer, allow_nil?: false, default: 1, public?: true
        attribute :submitted_at, :utc_datetime_usec, allow_nil?: false, public?: true
        timestamps()
      end

      relationships do
        #{Recipe.belongs_to(:subject, names.subject, config.key_types.subject)}
        #{Recipe.belongs_to(:requested_by, names.reviewer, config.key_types.reviewer)}

        has_many :decisions, #{inspect(names.decision)} do
          destination_attribute :review_id
          sort round: :asc
          public? true
        end
      end
      """
    end

    defp decision_transitions do
      """
      transition :request_changes, to: :changes_requested
      transition :approve, to: :approved
      transition :reject, to: :rejected
      """
    end

    defp overdue_timeout(nil), do: ""

    defp overdue_timeout(duration) do
      "timeout :overdue, fire_after: #{inspect(duration)}, field: :submitted_at, transition_to: :overdue"
    end

    defp overdue_step(nil), do: ""

    defp overdue_step(_duration) do
      """
      step :overdue do
        #{decision_transitions()}
      end
      """
    end

    defp decision_contents(names, storage, reviewer_key_type) do
      """
      use Ash.Resource,
        domain: #{inspect(storage.domain)},
        #{Recipe.data_layer_option(storage)}
        authorizers: [Ash.Policy.Authorizer]

      #{Recipe.postgres_block(storage, names.decision, Recipe.identity_index_name(names.decision, :unique_round))}

      actions do
        defaults [:read]

        create :create do
          accept [:review_id, :round, :decision, :comment]
          change relate_actor(:reviewer, allow_nil?: true)
          change set_attribute(:decided_at, &DateTime.utc_now/0)
        end
      end

      # Decisions are created only by the review's :request_changes, :approve
      # and :reject actions, which skip authorization for it.
      policies do
        policy action_type(:read) do
          authorize_if always()
        end
      end

      attributes do
        uuid_v7_primary_key :id
        attribute :round, :integer, allow_nil?: false, public?: true

        attribute :decision, :atom do
          allow_nil? false
          constraints one_of: [:changes_requested, :approved, :rejected]
          public? true
        end

        attribute :comment, :string, public?: true
        attribute :decided_at, :utc_datetime_usec, allow_nil?: false, public?: true
      end

      relationships do
        #{Recipe.belongs_to(:review, names.review, nil)}
        #{reviewer_belongs_to(names.reviewer, reviewer_key_type)}
      end

      identities do
        identity :unique_round, [:review_id, :round]#{Recipe.pre_check_with(storage)}
      end
      """
    end

    # A decision made with no actor, such as by a system process with
    # `authorize?: false`, has no reviewer.
    defp reviewer_belongs_to(reviewer, key_type) do
      String.replace(
        Recipe.belongs_to(:reviewer, reviewer, key_type),
        "allow_nil?: false",
        "allow_nil?: true"
      )
    end

    defp record_decision_contents(names) do
      """
      @moduledoc "Records the actor's decision on the current round of the review being updated."

      use Ash.Resource.Change

      @impl true
      def change(changeset, opts, context) do
        Ash.Changeset.after_action(changeset, fn changeset, review ->
          #{inspect(names.decision)}
          |> Ash.Changeset.for_create(
            :create,
            %{
              review_id: review.id,
              round: review.round,
              decision: opts[:decision],
              comment: Ash.Changeset.get_argument(changeset, :comment)
            },
            actor: context.actor,
            authorize?: false
          )
          |> Ash.create()
          |> case do
            {:ok, _decision} -> {:ok, review}
            {:error, error} -> {:error, error}
          end
        end)
      end
      """
    end

    defp can_request_contents(names) do
      Recipe.deny_check_contents(
        "Decides who may open an `#{inspect(names.review)}` on a subject.",
        "actor may request a review of this subject"
      )
    end

    defp can_review_contents(names) do
      Recipe.deny_check_contents(
        "Decides who may approve, reject or request changes on an `#{inspect(names.review)}`.",
        "actor may review this review"
      )
    end
  end
else
  defmodule Mix.Tasks.AshWorkflow.Gen.Review do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_workflow.gen.review' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
