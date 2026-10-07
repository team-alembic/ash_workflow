defmodule AshWorkflowDemoWeb.ApplyLive do
  use AshWorkflowDemoWeb, :live_view

  alias AshWorkflowDemo.ATS.Candidate.SetResponseDelays

  @avatar_styles ~w(avataaars adventurer big-smile bottts fun-emoji micah)

  # Both of these end up on a projector. The caps are enforced here rather
  # than only by `maxlength`, which is the browser's suggestion and not a
  # limit any other client has to respect.
  @name_max_chars 60
  @pitch_max_chars 200

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       form: blank_form(),
       error: nil,
       name_max_chars: @name_max_chars,
       pitch_max_chars: @pitch_max_chars
     )}
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

      String.length(name) > @name_max_chars ->
        {:noreply, assign(socket, error: "name must be #{@name_max_chars} characters or fewer")}

      String.length(pitch) > @pitch_max_chars ->
        {:noreply, assign(socket, error: "pitch must be #{@pitch_max_chars} characters or fewer")}

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
    <div class="min-h-screen bg-cream flex items-center justify-center p-6">
      <div class="w-full max-w-md bg-paper border border-line rounded-2xl shadow-[8px_8px_0_theme(colors.ink)] p-8 space-y-6">
        <div class="text-center">
          <.brandmark class="justify-center text-3xl flex" />
          <p class="mt-4 text-xs font-semibold uppercase tracking-widest text-muted">
            Now hiring · one slot
          </p>
          <h1 class="mt-1 text-3xl font-serif font-extrabold text-ink">Chief Sediment Architect</h1>
          <p class="text-muted mt-2">Competitive base · equity · annual sand allowance</p>
          <ul class="mt-4 text-sm text-ink space-y-1">
            <li>Production Ash experience</li>
            <li>Distributed systems</li>
            <li>Granular data</li>
            <li>Eventual consistency</li>
            <li class="font-bold">Get your hands dirty</li>
          </ul>
        </div>

        <form phx-submit="submit" class="space-y-4">
          <div>
            <label class="block text-sm font-semibold text-ink">Your name</label>
            <input
              type="text"
              name="candidate[name]"
              value={@form["name"]}
              maxlength={@name_max_chars}
              autocomplete="off"
              class="mt-1 w-full rounded-lg bg-cream border-line text-ink placeholder:text-muted/60 shadow-sm focus:border-amber focus:ring-amber"
              placeholder="e.g. Lola"
              required
            />
          </div>

          <div>
            <label class="block text-sm font-semibold text-ink">
              Your pitch (max {@pitch_max_chars} chars)
            </label>
            <textarea
              name="candidate[pitch]"
              rows="4"
              maxlength={@pitch_max_chars}
              class="mt-1 w-full rounded-lg bg-cream border-line text-ink placeholder:text-muted/60 shadow-sm focus:border-amber focus:ring-amber"
              placeholder="Why should El Jefe hire you?"
              required
            ><%= @form["pitch"] %></textarea>
          </div>

          <%= if @error do %>
            <div class="text-orange text-sm">{@error}</div>
          <% end %>

          <button
            type="submit"
            class="w-full bg-amber text-ink font-black py-3 rounded-lg hover:bg-amber/85 transition"
          >
            Apply
          </button>
        </form>

        <p class="text-xs text-muted text-center">
          Warning: Janine has {SetResponseDelays.hr_max_seconds()} seconds to get to your pitch.
        </p>
      </div>
    </div>
    """
  end
end
