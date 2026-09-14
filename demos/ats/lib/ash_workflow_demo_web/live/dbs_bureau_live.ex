defmodule AshWorkflowDemoWeb.DbsBureauLive do
  @moduledoc """
  The bureau's own screen, meant to look like a different application from
  the kanban. It runs on a second screen or a phone over the tunnel, and it
  only ever knows a candidate by the reference it issued, not by our id.
  """

  use AshWorkflowDemoWeb, :live_view

  alias AshWorkflowDemo.ATS.DbsBureau

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AshWorkflowDemo.PubSub, "candidates:all")
    end

    {:ok, load_pending(socket)}
  end

  @impl true
  def handle_info({:candidate_changed, _id}, socket), do: {:noreply, load_pending(socket)}

  @impl true
  def handle_event("return_clear", %{"reference" => reference}, socket) do
    DbsBureau.return_result(reference, :clear)
    {:noreply, load_pending(socket)}
  end

  @impl true
  def handle_event("return_flagged", %{"reference" => reference}, socket) do
    DbsBureau.return_result(reference, :flagged)
    {:noreply, load_pending(socket)}
  end

  defp load_pending(socket), do: assign(socket, pending: DbsBureau.pending())

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-[#e8e8e4] text-[#1a1a1a] font-serif p-4">
      <header class="border-2 border-[#1a1a1a] bg-[#d8d8d2] p-4 mb-6">
        <div class="text-xs uppercase tracking-widest">
          Bureau of Disclosures &middot; Form DBS-7A
        </div>
        <h1 class="text-2xl font-bold mt-1">
          Disclosure &amp; Background Bureau &mdash; Employer Portal
        </h1>
        <p class="text-sm mt-1">
          Outstanding checks requiring a response. Reference numbers only. Do not disclose applicant
          identity outside this portal.
        </p>
      </header>

      <%= if @pending == [] do %>
        <div class="border-2 border-dashed border-[#7a7a74] bg-[#f2f2ee] p-8 text-center">
          <p class="text-lg font-bold">No outstanding checks.</p>
          <p class="text-sm mt-1">The queue is clear.</p>
        </div>
      <% else %>
        <div class="border-2 border-[#1a1a1a] bg-[#f2f2ee]">
          <div class="hidden sm:grid grid-cols-[1fr_1fr_auto] gap-2 bg-[#d8d8d2] border-b-2 border-[#1a1a1a] px-4 py-2 text-xs font-bold uppercase tracking-wide">
            <div>Reference</div>
            <div>Applicant</div>
            <div>Action</div>
          </div>

          <div class="divide-y-2 divide-[#1a1a1a]">
            <%= for c <- @pending do %>
              <div class="p-4 sm:grid sm:grid-cols-[1fr_1fr_auto] sm:items-center sm:gap-2">
                <div class="font-mono text-lg font-bold">{c.dbs_reference}</div>
                <div class="text-sm text-[#4a4a44] mt-1 sm:mt-0">{c.name}</div>
                <div class="flex flex-col sm:flex-row gap-2 mt-3 sm:mt-0">
                  <button
                    phx-click="return_clear"
                    phx-value-reference={c.dbs_reference}
                    class="border-2 border-[#1a1a1a] bg-[#f2f2ee] hover:bg-[#e0e0da] px-3 py-2 text-xs font-bold uppercase tracking-wide"
                  >
                    Return: No disclosures
                  </button>
                  <button
                    phx-click="return_flagged"
                    phx-value-reference={c.dbs_reference}
                    class="border-2 border-[#1a1a1a] bg-[#f2f2ee] hover:bg-[#e0e0da] px-3 py-2 text-xs font-bold uppercase tracking-wide"
                  >
                    Return: Disclosure found
                  </button>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <footer class="mt-6 text-xs text-[#4a4a44] border-t border-[#7a7a74] pt-2">
        Form DBS-7A/2026. Retain for your records. This portal is not affiliated with any employer
        it serves.
      </footer>
    </div>
    """
  end
end
