defmodule WorkflowTimeline.Seeder do
  @moduledoc """
  Builds incidents with realistic, backdated transition-log history for the
  timeline demo. Used by both `priv/repo/seeds.exs` and the "Generate
  incident history" button on the timeline page.

  `AshWorkflow.Changes.RecordEvent` always stamps `occurred_at` with
  `DateTime.utc_now/0`, so a live action can never write a backdated row.
  Instead this module runs the real actions — so every row is produced by
  the actual workflow, not hand-assembled — and afterwards rewrites the
  resulting rows' `occurred_at`, and the incident's denormalised
  `state_entered_at`, to whenever the scenario is supposed to have happened.
  """

  alias WorkflowTimeline.IncidentResponse
  alias WorkflowTimeline.IncidentResponse.{Incident, Responder}

  @titles [
    "Checkout latency spike",
    "Elevated 5xx on API gateway",
    "Background job queue backlog",
    "Search index falling behind",
    "Intermittent auth failures",
    "Cache eviction storm",
    "Webhook delivery delays",
    "Read replica lag alert"
  ]

  @scenarios [:fresh, :investigating, :reminders, :escalated, :resolved, :triage_failed]

  @doc """
  Creates one incident, walks it through a randomly chosen lifecycle
  scenario using the real workflow actions, then backdates its transition
  log so it looks like it started `started_ago` seconds in the past.
  """
  @spec seed_incident!(atom(), integer()) :: Ash.Resource.record()
  def seed_incident!(scenario \\ Enum.random(@scenarios), started_ago \\ random_start()) do
    incident = create_incident!()
    responder = random_responder()

    incident
    |> run_scenario!(scenario, responder)
    |> backdate!(started_ago)
  end

  @doc "Seeds `count` incidents spread across varied scenarios and start times."
  @spec seed_many!(non_neg_integer()) :: [Ash.Resource.record()]
  def seed_many!(count) do
    for _ <- 1..count, do: seed_incident!()
  end

  defp create_incident!() do
    title = Enum.random(@titles)

    {:ok, incident} =
      IncidentResponse.report(title, "#{title}. Reported by monitoring.")

    incident
  end

  defp run_scenario!(incident, :fresh, _responder), do: incident

  defp run_scenario!(incident, :triage_failed, _responder) do
    update!(incident, :__on_error_triaging, nil)
  end

  defp run_scenario!(incident, :investigating, _responder) do
    update!(incident, :classify_severity, nil)
  end

  defp run_scenario!(incident, :reminders, _responder) do
    incident = update!(incident, :classify_severity, nil)

    Enum.reduce(1..Enum.random(2..4), incident, fn _, incident ->
      update!(incident, :send_status_update, nil)
    end)
  end

  defp run_scenario!(incident, :escalated, responder) do
    incident = update!(incident, :classify_severity, nil)
    incident = update!(incident, :send_status_update, nil)
    incident = update!(incident, :send_status_update, nil)

    incident
    |> update!(:__timeout_investigating_auto_escalate, nil)
    |> then(&maybe_touch(&1, :resolve, responder, roll: 3))
  end

  defp run_scenario!(incident, :resolved, responder) do
    incident = update!(incident, :classify_severity, nil)
    update!(incident, :resolve, responder)
  end

  defp maybe_touch(incident, action, responder, roll: chance_in) do
    if Integer.mod(System.unique_integer([:positive]), chance_in) == 0 do
      update!(incident, action, responder)
    else
      incident
    end
  end

  defp update!(incident, action, actor) do
    {:ok, incident} = Ash.update(incident, action: action, actor: actor, authorize?: false)
    incident
  end

  defp random_responder do
    case Ash.read!(Responder, authorize?: false) do
      [] -> nil
      responders -> Enum.random(responders)
    end
  end

  defp backdate!(incident, started_ago) do
    history = Incident.history(incident)
    timestamps = spaced_timestamps(started_ago, length(history))

    history
    |> Enum.zip(timestamps)
    |> Enum.each(fn {row, occurred_at} ->
      row
      |> Ash.Changeset.for_update(:backdate, %{occurred_at: occurred_at}, authorize?: false)
      |> Ash.update!()
    end)

    incident
    |> Ash.Changeset.for_update(
      :seed_snapshot,
      %{state_entered_at: List.last(timestamps)},
      authorize?: false
    )
    |> Ash.update!()
  end

  defp spaced_timestamps(_started_ago, 0), do: []

  defp spaced_timestamps(started_ago, count) do
    now = DateTime.utc_now()
    start = DateTime.add(now, -started_ago, :second)
    span = max(started_ago - 60, (count - 1) * 5)

    Enum.map(0..(count - 1), fn index ->
      fraction = if count == 1, do: 0.0, else: index / (count - 1)
      DateTime.add(start, round(fraction * span), :second)
    end)
  end

  defp random_start, do: Enum.random(1..10) * 86_400 - Enum.random(0..3_600)
end
