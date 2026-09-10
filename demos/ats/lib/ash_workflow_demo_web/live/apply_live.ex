defmodule AshWorkflowDemoWeb.ApplyLive do
  use AshWorkflowDemoWeb, :live_view

  alias AshWorkflowDemo.ATS.Candidate.Deadlines

  @avatar_styles ~w(avataaars adventurer big-smile bottts fun-emoji micah)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: blank_form(), error: nil)}
  end

  @impl true
  def handle_event("submit", %{"candidate" => params}, socket) do
    name = String.trim(params["name"] || "")
    pitch = String.trim(params["pitch"] || "")

    cond do
      name == "" ->
        {:noreply, assign(socket, error: "name cannot be empty")}

      pitch == "" ->
        {:noreply, assign(socket, error: "pitch cannot be empty")}

      String.length(pitch) > 200 ->
        {:noreply, assign(socket, error: "pitch must be 200 characters or fewer")}

      true ->
        avatar = build_avatar_url(name)

        case AshWorkflowDemo.ATS.start(name, pitch, avatar) do
          {:ok, candidate} -> {:noreply, push_navigate(socket, to: ~p"/c/#{candidate.id}")}
          {:error, err} -> {:noreply, assign(socket, error: "Error: #{inspect(err)}")}
        end
    end
  end

  defp blank_form, do: %{"name" => "", "pitch" => ""}

  defp build_avatar_url(name) do
    style = Enum.random(@avatar_styles)
    seed = "#{name}-#{System.unique_integer([:positive])}"
    "https://api.dicebear.com/7.x/#{style}/svg?seed=#{URI.encode(seed)}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-amber-500 to-red-700 flex items-center justify-center p-6">
      <div class="w-full max-w-md bg-white rounded-2xl shadow-2xl p-8 space-y-6">
        <div class="text-center">
          <div class="text-5xl mb-2">🤠</div>
          <h1 class="text-3xl font-extrabold">¿Y usted quién es?</h1>
          <p class="text-stone-600 mt-2">El Jefe is hiring. One slot. Make it count.</p>
        </div>

        <form phx-submit="submit" class="space-y-4">
          <div>
            <label class="block text-sm font-semibold text-stone-700">Your name</label>
            <input
              type="text"
              name="candidate[name]"
              value={@form["name"]}
              autocomplete="off"
              class="mt-1 w-full rounded-lg border-stone-300 shadow-sm focus:border-amber-500 focus:ring-amber-500"
              placeholder="e.g. Lola"
              required
            />
          </div>

          <div>
            <label class="block text-sm font-semibold text-stone-700">
              Your pitch (max 200 chars)
            </label>
            <textarea
              name="candidate[pitch]"
              rows="4"
              maxlength="200"
              class="mt-1 w-full rounded-lg border-stone-300 shadow-sm focus:border-amber-500 focus:ring-amber-500"
              placeholder="Why should El Jefe hire you?"
              required
            ><%= @form["pitch"] %></textarea>
          </div>

          <%= if @error do %>
            <div class="text-red-600 text-sm">{@error}</div>
          <% end %>

          <button
            type="submit"
            class="w-full bg-red-700 text-white font-bold py-3 rounded-lg hover:bg-red-800 transition"
          >
            Apply
          </button>
        </form>

        <p class="text-xs text-stone-500 text-center">
          Warning: El Jefe has {Deadlines.seconds(:auto_reject)} seconds to decide.
        </p>
      </div>
    </div>
    """
  end
end
