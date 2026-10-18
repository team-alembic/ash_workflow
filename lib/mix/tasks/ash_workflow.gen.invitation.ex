defmodule Mix.Tasks.AshWorkflow.Gen.Invitation.Docs do
  @moduledoc false

  def short_doc do
    "Adds an invitation workflow to a resource"
  end

  def example do
    "mix ash_workflow.gen.invitation MyApp.Teams.Team --invitee MyApp.Accounts.User --expires-after 7d"
  end

  def long_doc do
    """
    #{short_doc()}

    Generates an invitation resource that invites an email address to the
    subject. An invitation is accepted, declined or revoked, and expires once
    its `expires_at` passes. `resend` moves `expires_at` forward again. The
    subject gains `has_many :invitations` and `has_one :latest_invitation`.
    When the subject does not exist, it is created with `mix ash.gen.resource`
    first.

    Nobody may accept or decline until the application defines how an actor
    proves they are the invitee, in the generated `Checks.CanAccept` module.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--invitee` - required. The actor resource. The inviter and the invitee
      who accepts belong to it.
    * `--expires-after` - how long an invitation stays open after it is sent
      or resent, given as `30m`, `12h`, `2d` or `2w`. Defaults to `7d`.
    * `--module` - the invitation resource's module name. Defaults to the
      subject's name with `Invitation` appended.
    * `--domain` - the domain for a subject the task creates. Required only
      when the subject does not exist.
    * `--transition-log` - also generates a transition log for the invitation
      with `mix ash_workflow.gen.transition_log`. Defaults to `true`.
    """
  end
end

# Guarded on the struct this task builds rather than on `Igniter` itself. See
# `Mix.Tasks.AshWorkflow.Gen.TransitionLog` for why.
if Code.ensure_loaded?(Igniter.Mix.Task.Info) do
  defmodule Mix.Tasks.AshWorkflow.Gen.Invitation do
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
          invitee: :string,
          expires_after: :string,
          module: :string,
          domain: :string,
          transition_log: :boolean
        ],
        defaults: [expires_after: "7d", transition_log: true],
        required: [:invitee]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      subject = ProjectModule.parse(igniter.args.positional.subject)

      case Recipe.parse_duration(options[:expires_after], "--expires-after") do
        {:ok, expires_after} ->
          invitation = invitation_module(subject, options[:module])
          invitee = ProjectModule.parse(options[:invitee])

          config = %{
            subject: subject,
            invitee: invitee,
            invitation: invitation,
            can_accept: Module.concat([invitation, Checks, CanAccept]),
            no_open_invitation: Module.concat([invitation, Validations, NoOpenInvitation]),
            set_expires_at: Module.concat([invitation, Changes, SetExpiresAt]),
            expires_after: expires_after,
            transition_log?: options[:transition_log]
          }

          case Recipe.ensure_subject(
                 igniter,
                 subject,
                 options[:domain],
                 "invitation",
                 [invitee]
               ) do
            {:ok, igniter, storage} -> generate(igniter, config, storage)
            {:error, igniter} -> igniter
          end

        {:error, message} ->
          Igniter.add_issue(igniter, message)
      end
    end

    defp invitation_module(subject, nil), do: Module.concat([inspect(subject) <> "Invitation"])
    defp invitation_module(_subject, module), do: ProjectModule.parse(module)

    defp generate(igniter, config, storage) do
      {exists?, igniter} = ProjectModule.module_exists(igniter, config.invitation)

      igniter
      |> Recipe.add_subject_edits(
        config.subject,
        [
          invitations: """
          has_many :invitations, #{inspect(config.invitation)} do
            destination_attribute :subject_id
            public? true
          end
          """,
          latest_invitation: """
          has_one :latest_invitation, #{inspect(config.invitation)} do
            destination_attribute :subject_id
            from_many? true
            sort inserted_at: :desc
            public? true
          end
          """
        ],
        []
      )
      |> then(fn igniter ->
        if exists?, do: igniter, else: create_invitation(igniter, config, storage)
      end)
    end

    defp create_invitation(igniter, config, storage) do
      igniter
      |> ProjectModule.create_module(config.invitation, invitation_contents(config, storage))
      |> ProjectModule.create_module(config.can_accept, can_accept_contents(config))
      |> ProjectModule.create_module(
        config.no_open_invitation,
        no_open_invitation_contents(config)
      )
      |> ProjectModule.create_module(config.set_expires_at, set_expires_at_contents(config))
      |> DomainIgniter.add_resource_reference(storage.domain, config.invitation)
      |> compose_transition_log(config)
      |> Igniter.add_notice("""
      Generated #{inspect(config.invitation)} to invite people to #{inspect(config.subject)}.

      Nobody can accept or decline an invitation yet. Define how an actor \
      proves they are the invitee in #{inspect(config.can_accept)}, which \
      denies everyone as generated. Delivering the invitation is up to the \
      application.
      """)
    end

    defp compose_transition_log(igniter, %{transition_log?: false}), do: igniter

    defp compose_transition_log(igniter, config),
      do: Recipe.compose_transition_log(igniter, config.invitation, config.invitee)

    defp invitation_contents(config, storage) do
      """
      use Ash.Resource,
        domain: #{inspect(storage.domain)},
        #{Recipe.data_layer_option(storage)}
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshWorkflow, AshOban]

      #{Recipe.postgres_block(storage, config.invitation, postgres_identity(config.invitation))}

      workflow do
        step :sent do
          transition :accept, to: :accepted
          transition :decline, to: :declined
          transition :revoke, to: :revoked
          transition :resend, to: :sent

          timeout :expired do
            fire_at :expires_at
            transition_to :expired
          end
        end

        step :accepted, terminal: true
        step :declined, terminal: true
        step :revoked, terminal: true
        step :expired, terminal: true
      end

      code_interface do
        define :invite, args: [:subject_id, :email]
        define :accept
        define :decline
        define :revoke
        define :resend
      end

      actions do
        defaults [:read]

        create :invite do
          accept [:subject_id, :email]
          change relate_actor(:invited_by)
          change #{inspect(config.set_expires_at)}
          validate #{inspect(config.no_open_invitation)}
        end

        update :accept do
          require_atomic? false
          validate compare(:expires_at, greater_than: &DateTime.utc_now/0), message: "has expired"
          change relate_actor(:invitee)
        end

        update :resend do
          require_atomic? false
          change #{inspect(config.set_expires_at)}
        end
      end

      policies do
        policy action([:accept, :decline]) do
          authorize_if #{inspect(config.can_accept)}
        end

        policy action([:revoke, :resend]) do
          authorize_if relates_to_actor_via(:invited_by)
        end
      end

      attributes do
        uuid_v7_primary_key :id
        attribute :email, :ci_string, allow_nil?: false, public?: true
        attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
        timestamps()
      end

      relationships do
        belongs_to :subject, #{inspect(config.subject)}, allow_nil?: false, public?: true
        belongs_to :invited_by, #{inspect(config.invitee)}, allow_nil?: false, public?: true
        belongs_to :invitee, #{inspect(config.invitee)}, public?: true
      end

      #{postgres_identities(storage)}
      """
    end

    defp set_expires_at_contents(%{expires_after: {count, unit}} = config) do
      """
      @moduledoc "Sets `expires_at` on an `#{inspect(config.invitation)}` to the end of its open period."

      use Ash.Resource.Change

      @impl true
      def change(changeset, _opts, _context) do
        expires_at = DateTime.add(DateTime.utc_now(), #{count}, #{inspect(time_unit(unit))})
        Ash.Changeset.force_change_attribute(changeset, :expires_at, expires_at)
      end
      """
    end

    defp time_unit(:minutes), do: :minute
    defp time_unit(:hours), do: :hour
    defp time_unit(:days), do: :day

    defp postgres_identity(invitation) do
      """
      #{Recipe.identity_index_name(invitation, :unique_open_email)}
      identity_wheres_to_sql unique_open_email: "state = 'sent'"
      """
    end

    # Ash's pre-check for an identity ignores its `where`, so on other data
    # layers NoOpenInvitation is the only guard.
    defp postgres_identities(%{data_layer: AshPostgres.DataLayer}) do
      """
      identities do
        identity :unique_open_email, [:subject_id, :email], where: expr(state == :sent)
      end
      """
    end

    defp postgres_identities(_storage), do: ""

    defp can_accept_contents(config) do
      """
      @moduledoc \"\"\"
      Decides who may accept or decline an `#{inspect(config.invitation)}`.

      Denies everyone until the application replaces `match?/3`.
      \"\"\"

      use Ash.Policy.SimpleCheck

      @impl true
      def describe(_opts), do: "actor is the invitee of this invitation"

      @impl true
      def match?(_actor, _context, _opts), do: false
      """
    end

    defp no_open_invitation_contents(config) do
      """
      @moduledoc "Refuses an invitation to an email that already has one open for the same subject."

      use Ash.Resource.Validation

      require Ash.Query

      @impl true
      def validate(changeset, _opts, _context) do
        subject_id = Ash.Changeset.get_attribute(changeset, :subject_id)
        email = Ash.Changeset.get_attribute(changeset, :email)

        if subject_id && email && open_invitation?(subject_id, email) do
          {:error, field: :email, message: "already has an open invitation"}
        else
          :ok
        end
      end

      defp open_invitation?(subject_id, email) do
        #{inspect(config.invitation)}
        |> Ash.Query.filter(subject_id == ^subject_id and email == ^email and state == :sent)
        |> Ash.exists?(authorize?: false)
      end
      """
    end
  end
else
  defmodule Mix.Tasks.AshWorkflow.Gen.Invitation do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_workflow.gen.invitation' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
