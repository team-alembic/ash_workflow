defmodule Mix.Tasks.AshWorkflow.Gen.InvitationTest do
  use AshWorkflow.RecipeCase, async: true

  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.RecipeFixtures.Invitation.Domain
  alias AshWorkflowTest.RecipeFixtures.Invitation.Event
  alias AshWorkflowTest.RecipeFixtures.Invitation.Team
  alias AshWorkflowTest.RecipeFixtures.Invitation.TeamInvitation
  alias AshWorkflowTest.RecipeFixtures.Invitation.TeamInvitationTransition
  alias AshWorkflowTest.RecipeFixtures.Invitation.User

  @fixtures "test/support/recipe_fixtures/invitation"
  @files ["#{@fixtures}/domain.ex", "#{@fixtures}/user.ex", "#{@fixtures}/team.ex"]
  @can_accept "lib/ash_workflow_test/recipe_fixtures/invitation/team_invitation/checks/can_accept.ex"
  @day 86_400

  defp generate(files \\ @files, argv) do
    files
    |> project()
    |> run_task("ash_workflow.gen.invitation", argv)
  end

  defp invitation_for_teams(tmp_dir, argv \\ []) do
    [inspect(Team), "--invitee", inspect(User) | argv]
    |> generate()
    |> allow_invitees()
    |> compile(tmp_dir)
  end

  # What an application does once it has generated the recipe: fill in
  # CanAccept. Here an actor proves they are the invitee by their email.
  defp allow_invitees(recipe) do
    edit_source(recipe, @can_accept, fn source ->
      String.replace(
        source,
        "def match?(_actor, _context, _opts), do: false",
        """
        def match?(%{email: email}, %{subject: %{data: invitation}}, _opts),
          do: Ash.CiString.compare(email, invitation.email) == :eq

        def match?(_actor, _context, _opts), do: false
        """
      )
    end)
  end

  # `compile/2` reads every file from the project, not only the changed ones.
  defp edit_source(recipe, path, fun) do
    recipe
    |> update_in([Access.key!(:changed), path], fun)
    |> update_in([Access.key!(:igniter), Access.key!(:assigns), :test_files, path], fun)
  end

  defp user(recipe, email) do
    recipe.modules[User]
    |> Ash.Changeset.for_create(:create, %{email: email})
    |> Ash.create!()
  end

  defp team(recipe) do
    recipe.modules[Team]
    |> Ash.Changeset.for_create(:create, %{name: "Platform"})
    |> Ash.create!()
  end

  defp invite(recipe, team, inviter, email) do
    recipe.modules[TeamInvitation]
    |> Ash.Changeset.for_create(:invite, %{subject_id: team.id, email: email}, actor: inviter)
    |> Ash.create()
  end

  defp invited_days_ago(recipe, team, inviter, email, days) do
    recipe.modules[TeamInvitation]
    |> Ash.Changeset.for_create(:invite, %{subject_id: team.id, email: email}, actor: inviter)
    |> Ash.Changeset.force_change_attribute(:expires_at, days_from_now(7 - days))
    |> Ash.create!()
  end

  defp act(invitation, action, actor) do
    invitation
    |> Ash.Changeset.for_update(action, %{}, actor: actor)
    |> Ash.update()
  end

  defp days_from_now(days), do: DateTime.add(DateTime.utc_now(), days, :day)

  defp reload(invitation), do: Ash.get!(invitation.__struct__, invitation.id)

  defp seconds_until(datetime), do: DateTime.diff(datetime, DateTime.utc_now(), :second)

  describe "an existing subject" do
    test "keeps its own attributes and actions and gains only the two relationships", %{
      tmp_dir: tmp_dir
    } do
      recipe = invitation_for_teams(tmp_dir)
      subject = recipe.modules[Team]

      assert attributes(subject) == attributes(Team)
      assert actions(subject) == actions(Team)

      assert names(Ash.Resource.Info.relationships(subject)) --
               names(Ash.Resource.Info.relationships(Team)) == [
               :invitations,
               :latest_invitation
             ]

      assert names(Ash.Resource.Info.calculations(subject)) ==
               names(Ash.Resource.Info.calculations(Team))
    end

    test "lists its invitations, newest as the latest", %{tmp_dir: tmp_dir} do
      recipe = invitation_for_teams(tmp_dir)
      team = team(recipe)
      inviter = user(recipe, "owner@example.com")

      {:ok, first} = invite(recipe, team, inviter, "ada@example.com")
      {:ok, second} = invite(recipe, team, inviter, "grace@example.com")

      team = Ash.load!(team, [:invitations, :latest_invitation])
      assert Enum.sort(Enum.map(team.invitations, & &1.id)) == Enum.sort([first.id, second.id])
      assert team.latest_invitation.id == second.id
    end
  end

  test "creates a missing subject in the given domain and invites to it", %{tmp_dir: tmp_dir} do
    recipe =
      ["#{@fixtures}/domain.ex", "#{@fixtures}/user.ex"]
      |> generate([inspect(Event), "--invitee", inspect(User), "--domain", inspect(Domain)])
      |> compile(tmp_dir)

    event_module = recipe.modules[Event]
    invitation_module = recipe.modules[AshWorkflowTest.RecipeFixtures.Invitation.EventInvitation]

    assert Ash.Resource.Info.data_layer(event_module) == Ash.DataLayer.Ets
    assert event_module in Ash.Domain.Info.resources(recipe.modules[Domain])

    event = event_module |> Ash.Changeset.for_create(:create, %{}) |> Ash.create!()

    invitation =
      invitation_module
      |> Ash.Changeset.for_create(:invite, %{subject_id: event.id, email: "ada@example.com"},
        actor: user(recipe, "host@example.com")
      )
      |> Ash.create!()

    assert invitation.state == :sent
    assert Ash.load!(event, latest_invitation: :id).latest_invitation.id == invitation.id
  end

  test "running the task a second time changes nothing" do
    argv = [inspect(Team), "--invitee", inspect(User), "--expires-after", "2d"]
    first = generate(argv)
    second = run_task(first.igniter, "ash_workflow.gen.invitation", argv)

    assert second.changed == %{}
    assert second.warnings == []
  end

  describe "CanAccept" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Team), "--invitee", inspect(User)]
        |> generate()
        |> compile(tmp_dir)

      invitee = user(recipe, "ada@example.com")

      {:ok, invitation} =
        invite(recipe, team(recipe), user(recipe, "owner@example.com"), invitee.email)

      assert {:error, %Ash.Error.Forbidden{}} = act(invitation, :accept, invitee)
      assert {:error, %Ash.Error.Forbidden{}} = act(invitation, :decline, invitee)
      assert reload(invitation).state == :sent

      assert Enum.any?(
               recipe.notices,
               &String.contains?(&1, "Nobody can accept or decline an invitation yet")
             )
    end

    test "lets the invitee accept once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = invitation_for_teams(tmp_dir)
      invitee = user(recipe, "ada@example.com")

      {:ok, invitation} =
        invite(recipe, team(recipe), user(recipe, "owner@example.com"), "Ada@Example.com")

      assert {:error, %Ash.Error.Forbidden{}} =
               act(invitation, :accept, user(recipe, "grace@example.com"))

      assert {:ok, %{state: :accepted} = accepted} = act(invitation, :accept, invitee)
      assert accepted.invitee_id == invitee.id
    end

    test "lets the invitee decline once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = invitation_for_teams(tmp_dir)
      invitee = user(recipe, "ada@example.com")

      {:ok, invitation} =
        invite(recipe, team(recipe), user(recipe, "owner@example.com"), invitee.email)

      assert {:error, %Ash.Error.Forbidden{}} =
               act(invitation, :decline, user(recipe, "grace@example.com"))

      assert {:ok, %{state: :declined, invitee_id: nil}} = act(invitation, :decline, invitee)
    end
  end

  describe "the inviter" do
    test "is the only one who can revoke", %{tmp_dir: tmp_dir} do
      recipe = invitation_for_teams(tmp_dir)
      inviter = user(recipe, "owner@example.com")
      invitee = user(recipe, "ada@example.com")
      {:ok, invitation} = invite(recipe, team(recipe), inviter, invitee.email)

      assert {:error, %Ash.Error.Forbidden{}} = act(invitation, :revoke, invitee)
      assert {:ok, %{state: :revoked}} = act(invitation, :revoke, inviter)
    end

    test "is the only one who can resend", %{tmp_dir: tmp_dir} do
      recipe = invitation_for_teams(tmp_dir)
      inviter = user(recipe, "owner@example.com")
      invitee = user(recipe, "ada@example.com")
      {:ok, invitation} = invite(recipe, team(recipe), inviter, invitee.email)

      assert {:error, %Ash.Error.Forbidden{}} = act(invitation, :resend, invitee)
      assert {:ok, %{state: :sent}} = act(invitation, :resend, inviter)
    end
  end

  describe "the expiry deadline" do
    test "expires an invitation nobody answered once expires_at passes", %{tmp_dir: tmp_dir} do
      recipe = invitation_for_teams(tmp_dir)
      team = team(recipe)
      inviter = user(recipe, "owner@example.com")

      {:ok, fresh} = invite(recipe, team, inviter, "ada@example.com")
      lapsed = invited_days_ago(recipe, team, inviter, "grace@example.com", 8)

      assert Timeline.run_due(recipe.modules[TeamInvitation]) == 1
      assert reload(fresh).state == :sent
      assert reload(lapsed).state == :expired

      log =
        recipe.modules[TeamInvitationTransition] |> Ash.read!() |> Enum.map(& &1.to_state)

      assert Enum.sort(log) == [:expired, :sent, :sent]
    end

    test "resend moves expires_at a full period from now and re-arms the deadline", %{
      tmp_dir: tmp_dir
    } do
      recipe = invitation_for_teams(tmp_dir, ["--expires-after", "1s"])
      inviter = user(recipe, "owner@example.com")
      invitation = invited_days_ago(recipe, team(recipe), inviter, "ada@example.com", 8)

      assert {:ok, %{state: :sent} = resent} = act(invitation, :resend, inviter)

      assert_in_delta DateTime.diff(resent.expires_at, DateTime.utc_now(), :millisecond),
                      1000,
                      500

      assert Timeline.run_due(recipe.modules[TeamInvitation]) == 0
      assert reload(invitation).state == :sent

      Process.sleep(
        max(DateTime.diff(resent.expires_at, DateTime.utc_now(), :millisecond), 0) + 50
      )

      assert Timeline.run_due(recipe.modules[TeamInvitation]) == 1
      assert reload(invitation).state == :expired
    end

    test "an invitation past expires_at cannot be accepted before the sweep runs", %{
      tmp_dir: tmp_dir
    } do
      recipe = invitation_for_teams(tmp_dir)
      invitee = user(recipe, "ada@example.com")

      invitation =
        invited_days_ago(
          recipe,
          team(recipe),
          user(recipe, "owner@example.com"),
          invitee.email,
          8
        )

      assert {:error, %Ash.Error.Invalid{}} = act(invitation, :accept, invitee)
      assert reload(invitation).state == :sent
    end

    test "an expired invitation is final", %{tmp_dir: tmp_dir} do
      recipe = invitation_for_teams(tmp_dir)
      inviter = user(recipe, "owner@example.com")
      invitee = user(recipe, "ada@example.com")
      invitation = invited_days_ago(recipe, team(recipe), inviter, invitee.email, 8)

      Timeline.run_due(recipe.modules[TeamInvitation])
      expired = reload(invitation)

      assert {:error, %Ash.Error.Invalid{}} = act(expired, :resend, inviter)
      assert {:error, _error} = act(expired, :accept, invitee)
      assert reload(invitation).state == :expired
    end

    for {flag, seconds} <- [
          {"10s", 10},
          {"30m", 30 * 60},
          {"12h", 12 * 3600},
          {"2d", 2 * @day},
          {"2w", 14 * @day}
        ] do
      test "--expires-after #{flag} sets expires_at #{seconds} seconds after invite and resend",
           %{tmp_dir: tmp_dir} do
        recipe = invitation_for_teams(tmp_dir, ["--expires-after", unquote(flag)])
        inviter = user(recipe, "owner@example.com")
        {:ok, invitation} = invite(recipe, team(recipe), inviter, "ada@example.com")

        assert_in_delta seconds_until(invitation.expires_at), unquote(seconds), 5

        {:ok, resent} = act(invitation, :resend, inviter)
        assert_in_delta seconds_until(resent.expires_at), unquote(seconds), 5
      end
    end

    test "without --expires-after an invitation is open for 7 days", %{tmp_dir: tmp_dir} do
      recipe = invitation_for_teams(tmp_dir)

      {:ok, invitation} =
        invite(recipe, team(recipe), user(recipe, "owner@example.com"), "a@example.com")

      assert_in_delta seconds_until(invitation.expires_at), 7 * @day, 5
    end

    test "reports an issue for a duration it cannot parse" do
      igniter =
        @files
        |> project()
        |> Igniter.compose_task("ash_workflow.gen.invitation", [
          inspect(Team),
          "--invitee",
          inspect(User),
          "--expires-after",
          "2y"
        ])

      assert Enum.any?(igniter.issues, &String.contains?(&1, "--expires-after must look like"))
    end
  end

  describe "one open invitation per address" do
    test "refuses a second open invitation to the same email in any case", %{tmp_dir: tmp_dir} do
      recipe = invitation_for_teams(tmp_dir)
      team = team(recipe)
      inviter = user(recipe, "owner@example.com")

      assert {:ok, _invitation} = invite(recipe, team, inviter, "ada@example.com")
      assert {:error, %Ash.Error.Invalid{}} = invite(recipe, team, inviter, "ADA@example.com")
      assert {:ok, _other_team} = invite(recipe, team(recipe), inviter, "ada@example.com")
    end

    test "allows a new invitation once the open one is closed", %{tmp_dir: tmp_dir} do
      recipe = invitation_for_teams(tmp_dir)
      team = team(recipe)
      inviter = user(recipe, "owner@example.com")

      {:ok, invitation} = invite(recipe, team, inviter, "ada@example.com")
      {:ok, _revoked} = act(invitation, :revoke, inviter)

      assert {:ok, %{state: :sent}} = invite(recipe, team, inviter, "ada@example.com")
    end
  end

  test "generates a Postgres-backed resource with a partial unique identity", %{tmp_dir: tmp_dir} do
    recipe =
      [
        "test/support/recipe_fixtures/transition_log/postgres_domain.ex",
        "test/support/recipe_fixtures/transition_log/postgres_ticket.ex"
      ]
      |> generate([
        "AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresTicket",
        "--invitee",
        "AshWorkflowTest.RecipeFixtures.TransitionLog.Reviewer"
      ])
      |> compile(tmp_dir)

    for {module, table} <- [
          PostgresTicketInvitation: "postgres_ticket_invitations",
          PostgresTicketInvitationTransition: "postgres_ticket_invitations_transitions"
        ] do
      resource =
        recipe.modules[Module.concat(AshWorkflowTest.RecipeFixtures.TransitionLog, module)]

      assert AshPostgres.DataLayer.Info.repo(resource) == AshWorkflowTest.Repo
      assert AshPostgres.DataLayer.Info.table(resource) == table
    end

    invitation =
      recipe.modules[AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresTicketInvitation]

    assert [%{name: :unique_open_email, keys: [:subject_id, :email]}] =
             Ash.Resource.Info.identities(invitation)

    assert AshPostgres.DataLayer.Info.identity_wheres_to_sql(invitation) ==
             [unique_open_email: "state = 'sent'"]
  end

  test "--no-transition-log generates no transition log" do
    recipe = generate([inspect(Team), "--invitee", inspect(User), "--no-transition-log"])

    refute Enum.any?(Map.keys(recipe.changed), &String.ends_with?(&1, "_transition.ex"))
  end

  test "reports an issue for a missing subject without --domain" do
    igniter =
      ["#{@fixtures}/domain.ex", "#{@fixtures}/user.ex"]
      |> project()
      |> Igniter.compose_task("ash_workflow.gen.invitation", [
        inspect(Event),
        "--invitee",
        inspect(User)
      ])

    assert Enum.any?(igniter.issues, &String.contains?(&1, "Pass --domain to create it"))
  end

  defp names(entities), do: Enum.map(entities, & &1.name)

  # Spark metadata records the file each entity was compiled from, which
  # differs between the fixture and the generated copy.
  defp attributes(resource) do
    resource |> Ash.Resource.Info.attributes() |> Enum.map(&Map.delete(&1, :__spark_metadata__))
  end

  defp actions(resource) do
    for action <- Ash.Resource.Info.actions(resource) do
      changes = action |> Map.get(:changes, []) |> Enum.map(& &1.change)
      {action.name, action.type, Map.get(action, :accept), changes, names(action.arguments)}
    end
  end
end
