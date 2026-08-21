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

  defp state_copy(:verifying),
    do: {"Verifying…", "El Jefe's people are checking you out.", "bg-amber-500"}

  defp state_copy(:review),
    do: {"Under review", "El Jefe has 30 seconds to decide.", "bg-blue-600"}

  defp state_copy(:hired),
    do: {"¡HIRED!", "You are El Jefe's new hire. Felicidades.", "bg-emerald-600"}

  defp state_copy(:rejected), do: {"Rejected", "No dice. Better luck next time.", "bg-stone-600"}

  defp state_copy(:auto_rejected),
    do: {"Auto-rejected", "El Jefe didn't decide in time. Tough town.", "bg-stone-600"}

  defp state_copy(:position_filled),
    do: {"Position filled", "Someone else got the slot. Vaya con Dios.", "bg-stone-600"}

  defp state_copy(:verification_failed),
    do: {"Verification failed", "Something broke. Not you. Probably.", "bg-red-600"}

  defp state_copy(_), do: {"—", "", "bg-stone-400"}

  @impl true
  def render(assigns) do
    {heading, sub, color} = state_copy(assigns.candidate.state)
    assigns = assign(assigns, heading: heading, sub: sub, color: color)

    ~H"""
    <div class={"min-h-screen flex flex-col items-center justify-center p-6 text-white " <> @color}>
      <img src={@candidate.avatar_url} class="w-48 h-48 rounded-full bg-white p-2 shadow-2xl mb-6" />
      <h1 class="text-4xl font-extrabold">{@candidate.name}</h1>
      <div class="mt-8 text-5xl font-black tracking-tight text-center">{@heading}</div>
      <p class="mt-3 text-lg opacity-90 text-center max-w-sm">{@sub}</p>

      <%= if @candidate.score do %>
        <div class="mt-10 bg-white/20 backdrop-blur rounded-xl p-4 max-w-sm text-center">
          <div class="text-sm uppercase tracking-wider opacity-80">Your score</div>
          <div class="text-6xl font-black">{@candidate.score}/10</div>
          <div class="text-sm italic mt-2">"{@candidate.score_reason}"</div>
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
