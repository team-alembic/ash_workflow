defmodule WorkflowTimelineWeb.TimelineLive do
  @moduledoc """
  Gantt-like timeline of every incident's workflow history, with a slider
  that sweeps a playhead across every band at once.

  Each band is built from `Incident.history/1` — a list of transition-log
  rows — rather than from the incident's current `state`. A segment starts
  wherever `from_state != to_state`; a row where `from_state == to_state`
  (the repeating `:status_reminder` timeout) does not start a new segment,
  it is drawn as a tick mark on top of the segment it fired inside. That is
  the one thing this feature makes visible that `state_entered_at` alone
  never could: "three reminders fired, nothing changed."

  The slider is a single `<input type="range">` in a form with
  `phx-change` — no JS hook, no charting library. Moving it re-derives
  "state at this instant" per incident by walking each band's own segment
  list, the same `state_at/2` logic exposed as a code interface function,
  just applied to data already loaded in the socket instead of re-querying.
  """

  use WorkflowTimelineWeb, :live_view

  alias WorkflowTimeline.IncidentResponse
  alias WorkflowTimeline.IncidentResponse.Incident
  alias WorkflowTimeline.Seeder

  @slider_steps 1000

  @state_colors %{
    triaging: "bg-amber-400",
    investigating: "bg-blue-500",
    escalated: "bg-red-600",
    resolved: "bg-emerald-500",
    triage_failed: "bg-stone-500"
  }

  @state_labels %{
    triaging: "Triaging",
    investigating: "Investigating",
    escalated: "Escalated",
    resolved: "Resolved",
    triage_failed: "Triage failed"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_bands(socket, slider_position: @slider_steps)}
  end

  @impl true
  def handle_event("slide", %{"at" => at}, socket) do
    position = at |> String.to_integer() |> clamp(0, @slider_steps)
    {:noreply, assign(socket, slider_position: position, playhead: playhead_at(socket, position))}
  end

  @impl true
  def handle_event("generate_history", _params, socket) do
    Seeder.seed_incident!()
    {:noreply, load_bands(socket, slider_position: @slider_steps)}
  end

  defp load_bands(socket, slider_position: slider_position) do
    %{results: incidents} =
      IncidentResponse.list_incidents!(authorize?: false, load: [:entered_current_state_at])

    bands = Enum.map(incidents, &build_band/1)

    {window_start, window_end} = time_window(bands)

    socket
    |> assign(
      bands: bands,
      window_start: window_start,
      window_end: window_end,
      slider_position: slider_position
    )
    |> assign(playhead: playhead_from_window(window_start, window_end, slider_position))
  end

  defp build_band(incident) do
    history = Incident.history(incident)
    segments = segments_from_history(history)

    %{
      incident: incident,
      history: history,
      segments: segments,
      state_entered_at: incident.state_entered_at,
      entered_current_state_at: incident.entered_current_state_at
    }
  end

  defp segments_from_history([]), do: []

  defp segments_from_history([first | rest]) do
    initial = [%{state: first.to_state, start: first.occurred_at, ticks: []}]

    rest
    |> Enum.reduce(initial, fn row, [current | earlier] ->
      if row.from_state == row.to_state do
        [%{current | ticks: current.ticks ++ [row.occurred_at]} | earlier]
      else
        [%{state: row.to_state, start: row.occurred_at, ticks: []}, current | earlier]
      end
    end)
    |> Enum.reverse()
  end

  defp time_window(bands) do
    all_times =
      bands
      |> Enum.flat_map(fn band -> Enum.map(band.history, & &1.occurred_at) end)

    now = DateTime.utc_now()

    case all_times do
      [] ->
        {DateTime.add(now, -1, :hour), now}

      times ->
        earliest = Enum.min(times, DateTime)
        {earliest, now}
    end
  end

  defp playhead_from_window(window_start, window_end, position) do
    fraction = position / @slider_steps
    total_ms = DateTime.diff(window_end, window_start, :millisecond)
    DateTime.add(window_start, round(total_ms * fraction), :millisecond)
  end

  defp playhead_at(socket, position) do
    playhead_from_window(socket.assigns.window_start, socket.assigns.window_end, position)
  end

  defp state_at_playhead(segments, playhead) do
    segments
    |> Enum.filter(&(DateTime.compare(&1.start, playhead) != :gt))
    |> List.last()
    |> case do
      nil -> nil
      segment -> segment.state
    end
  end

  defp segment_style(segment, next_start, window_start, window_end) do
    finish = next_start || window_end
    total = max(DateTime.diff(window_end, window_start, :millisecond), 1)
    left = percent(DateTime.diff(segment.start, window_start, :millisecond), total)
    width = percent(DateTime.diff(finish, segment.start, :millisecond), total)
    "left: #{left}%; width: #{width}%;"
  end

  defp tick_style(tick, window_start, window_end) do
    total = max(DateTime.diff(window_end, window_start, :millisecond), 1)
    left = percent(DateTime.diff(tick, window_start, :millisecond), total)
    "left: #{left}%;"
  end

  defp percent(ms, total_ms), do: Float.round(ms / total_ms * 100, 3)

  defp playhead_style(window_start, window_end, playhead) do
    total = max(DateTime.diff(window_end, window_start, :millisecond), 1)
    left = percent(DateTime.diff(playhead, window_start, :millisecond), total)
    "left: #{left}%;"
  end

  defp clamp(value, min, max), do: value |> max(min) |> min(max)

  defp segments_with_next_start([]), do: []

  defp segments_with_next_start(segments) do
    starts = Enum.map(segments, & &1.start)
    next_starts = tl(starts) ++ [nil]
    Enum.zip(segments, next_starts)
  end

  defp state_color(state), do: Map.get(@state_colors, state, "bg-stone-300")
  defp state_label(nil), do: "—"
  defp state_label(state), do: Map.get(@state_labels, state, to_string(state))

  defp format_time(nil), do: "—"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d %H:%M:%S")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-stone-900 text-stone-100 p-6">
      <header class="mb-6">
        <div class="flex items-center gap-4">
          <h1 class="text-3xl font-black">Incident timeline</h1>
          <.link navigate={~p"/undo"} class="text-blue-400 hover:text-blue-300 underline">
            the same workflow, with undo →
          </.link>
        </div>
        <p class="text-stone-400">
          Drag the playhead to see what every incident's workflow state was at that instant —
          derived from the transition log, not from the current row.
        </p>
        <button
          phx-click="generate_history"
          class="mt-3 bg-blue-600 hover:bg-blue-700 px-4 py-2 rounded font-bold"
        >
          Generate incident history
        </button>
      </header>

      <div class="bg-stone-800 rounded-xl p-4 mb-6">
        <div class="flex items-center justify-between text-sm text-stone-400 mb-2">
          <span>{format_time(@window_start)}</span>
          <span class="font-bold text-stone-100">Playhead: {format_time(@playhead)}</span>
          <span>{format_time(@window_end)}</span>
        </div>
        <form phx-change="slide" id="playhead-form">
          <input
            type="range"
            name="at"
            min="0"
            max="1000"
            value={@slider_position}
            class="w-full"
          />
        </form>
      </div>

      <div class="space-y-4">
        <%= for band <- @bands do %>
          <div class="bg-stone-800 rounded-xl p-4">
            <div class="flex items-center justify-between mb-2">
              <div>
                <span class="font-bold">{band.incident.title}</span>
                <span class="text-xs text-stone-400 ml-2">{band.incident.severity}</span>
              </div>
              <div class="text-sm">
                <span class="text-stone-400">state at playhead:</span>
                <span class={
                  "ml-1 px-2 py-0.5 rounded text-xs font-bold " <>
                    state_color(state_at_playhead(band.segments, @playhead))
                }>
                  {state_label(state_at_playhead(band.segments, @playhead))}
                </span>
              </div>
            </div>

            <div class="relative h-8 bg-stone-900 rounded overflow-hidden">
              <%= for {segment, next_start} <- segments_with_next_start(band.segments) do %>
                <div
                  class={"absolute inset-y-0 " <> state_color(segment.state)}
                  style={segment_style(segment, next_start, @window_start, @window_end)}
                  title={state_label(segment.state)}
                >
                </div>
                <%= for tick <- segment.ticks do %>
                  <div
                    class="absolute inset-y-0 w-0.5 bg-white/80"
                    style={tick_style(tick, @window_start, @window_end)}
                    title="repeat timeout fired"
                  >
                  </div>
                <% end %>
              <% end %>
              <div
                class="absolute inset-y-0 w-0.5 bg-yellow-300"
                style={playhead_style(@window_start, @window_end, @playhead)}
              >
              </div>
            </div>

            <div class="flex justify-between text-xs text-stone-400 mt-2">
              <span>state_entered_at: {format_time(band.state_entered_at)}</span>
              <span>entered_current_state_at: {format_time(band.entered_current_state_at)}</span>
              <span>reminders sent: {band.incident.status_updates_sent}</span>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
