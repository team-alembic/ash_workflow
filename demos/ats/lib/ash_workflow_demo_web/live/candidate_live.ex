defmodule AshWorkflowDemoWeb.CandidateLive do
  use AshWorkflowDemoWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AshWorkflowDemo.PubSub, "candidates:#{id}")
    end

    case AshWorkflowDemo.ATS.get_candidate(id) do
      {:ok, c} -> {:ok, assign(socket, candidate: c)}
      _ -> {:ok, socket |> put_flash(:error, "Not found") |> push_navigate(to: "/apply")}
    end
  end

  @impl true
  def handle_info({:candidate_changed, id}, socket) do
    {:ok, c} = AshWorkflowDemo.ATS.get_candidate(id)
    {:noreply, assign(socket, candidate: c)}
  end

  defp state_copy(:hr_screen),
    do: {"HR screen", "Janine is reading your pitch.", "bg-amber-500"}

  defp state_copy(:hr_decision),
    do: {"HR screen", "Janine is reading your pitch.", "bg-amber-500"}

  defp state_copy(:background_check),
    do:
      {"Background check", "The bureau is running your history. Try not to think about it.",
       "bg-purple-600"}

  defp state_copy(:bureau_result),
    do:
      {"Background check", "The bureau is running your history. Try not to think about it.",
       "bg-purple-600"}

  defp state_copy(:lead_interview),
    do: {"Lead interview", "Steve is deciding whether you're the one.", "bg-indigo-600"}

  defp state_copy(:lead_decision),
    do: {"Lead interview", "Steve is deciding whether you're the one.", "bg-indigo-600"}

  defp state_copy(:final_approval),
    do: {"El Jefe is deciding", "It's his call now.", "bg-teal-600"}

  defp state_copy(:hired),
    do: {"¡HIRED!", "You are El Jefe's new hire. Felicidades.", "bg-emerald-600"}

  defp state_copy(:rejected), do: {"Rejected", "No dice. Better luck next time.", "bg-stone-600"}

  defp state_copy(_), do: {"—", "", "bg-stone-400"}

  # Whoever is holding the candidate up right now. The bureau, :hired and
  # :rejected show no face — the bureau is faceless on purpose, and by hired
  # or rejected nobody is left to wait on.
  defp reviewer_avatar(state) when state in [:hr_screen, :hr_decision],
    do: "/images/janine-hr.png"

  defp reviewer_avatar(state) when state in [:lead_interview, :lead_decision],
    do: "/images/steve-tech.png"

  defp reviewer_avatar(:final_approval), do: "/images/conor.png"
  defp reviewer_avatar(_state), do: nil

  defp reviewer_alt(state) when state in [:hr_screen, :hr_decision], do: "Janine, HR manager"

  defp reviewer_alt(state) when state in [:lead_interview, :lead_decision],
    do: "Steve, engineering lead"

  defp reviewer_alt(:final_approval), do: "El Jefe, the boss"
  defp reviewer_alt(_state), do: nil

  @impl true
  def render(assigns) do
    {heading, sub, color} = state_copy(assigns.candidate.state)

    assigns =
      assign(assigns,
        heading: heading,
        sub: sub,
        color: color,
        reviewer_avatar: reviewer_avatar(assigns.candidate.state),
        reviewer_alt: reviewer_alt(assigns.candidate.state)
      )

    ~H"""
    <div class={"min-h-screen flex flex-col items-center justify-center p-6 text-white " <> @color}>
      <img src={@candidate.avatar_url} class="w-48 h-48 rounded-full bg-white p-2 shadow-2xl mb-6" />
      <h1 class="text-4xl font-extrabold">{@candidate.name}</h1>
      <%= if @reviewer_avatar do %>
        <img
          src={@reviewer_avatar}
          alt={@reviewer_alt}
          class="mt-6 w-24 h-24 rounded-full object-cover ring-4 ring-white/70 shadow-xl"
        />
      <% end %>
      <div class="mt-6 text-5xl font-black tracking-tight text-center">{@heading}</div>
      <p class="mt-3 text-lg opacity-90 text-center max-w-sm">{@sub}</p>

      <%= if @candidate.dbs_offence do %>
        <div class="mt-8 w-full max-w-sm bg-red-700 border-4 border-white/80 rounded-xl p-5 text-center shadow-2xl">
          <div class="text-2xl font-black">⚠️ DISCLOSURE ON FILE</div>
          <div class="text-xl font-bold mt-3 leading-snug">{@candidate.dbs_offence}</div>
          <div class="text-sm mt-3 opacity-90">
            It's on the record. It has not sunk you — nobody's judging you for this one.
          </div>
        </div>
      <% end %>

      <%= if @candidate.score do %>
        <div class="mt-6 bg-white/20 backdrop-blur rounded-xl p-4 max-w-sm text-center">
          <div class="flex items-center justify-center gap-2">
            <img
              src="/images/janine-hr.png"
              alt="Janine, HR manager"
              class="w-8 h-8 rounded-full object-cover"
            />
            <div class="text-sm uppercase tracking-wider opacity-80">Janine's score</div>
          </div>
          <div class="text-6xl font-black">{@candidate.score}/10</div>
          <div class="text-sm italic mt-2">"{@candidate.score_reason}"</div>
        </div>
      <% end %>

      <%= if @candidate.lead_score do %>
        <div class="mt-6 bg-white/20 backdrop-blur rounded-xl p-4 max-w-sm text-center">
          <div class="flex items-center justify-center gap-2">
            <img
              src="/images/steve-tech.png"
              alt="Steve, engineering lead"
              class="w-8 h-8 rounded-full object-cover"
            />
            <div class="text-sm uppercase tracking-wider opacity-80">Steve's score</div>
          </div>
          <div class="text-6xl font-black">{@candidate.lead_score}/10</div>
          <%= if @candidate.lead_note do %>
            <div class="text-sm italic mt-2">"{@candidate.lead_note}"</div>
          <% end %>
        </div>
      <% end %>

      <%= if @candidate.state == :hired do %>
        <div class="mt-8 text-7xl animate-bounce">🎉</div>
      <% end %>

      <div class="mt-12 text-xs opacity-70">Pitch: "{@candidate.pitch}"</div>
    </div>
    """
  end
end
