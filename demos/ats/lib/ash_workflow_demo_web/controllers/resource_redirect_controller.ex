defmodule AshWorkflowDemoWeb.ResourceRedirectController do
  @moduledoc """
  Short links for the sources cited on the slides.

  A QR code on a slide has to survive being photographed from the back of a
  room, and an arXiv URL encodes to a dense code that does not. Each source
  gets a slug here instead, so the printed code stays coarse and the deck can
  print an address a person could also type.

  The map is the whole feature. Adding a source is adding a line.
  """

  use AshWorkflowDemoWeb, :controller

  @sources %{
    "pauli" => "https://arxiv.org/abs/quant-ph/9908033",
    "wheeler-dewitt" => "https://arxiv.org/abs/gr-qc/9210011",
    "rovelli" => "https://arxiv.org/abs/0903.3832",
    "arrow" => "https://plato.stanford.edu/entries/time-thermo/"
  }

  @doc "Every slug this controller knows, for tests and for the QR generator."
  def sources, do: @sources

  def show(conn, %{"slug" => slug}) do
    case Map.fetch(@sources, slug) do
      {:ok, url} -> redirect(conn, external: url)
      :error -> conn |> put_status(:not_found) |> text("Unknown source: #{slug}")
    end
  end
end
