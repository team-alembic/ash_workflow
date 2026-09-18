defmodule AshWorkflowDemo.ATS.DbsBureau do
  @moduledoc """
  The caller-side half of an external event, written out by hand.

  A candidate parked on `:background_check` is waiting for a result the bureau
  sends back against a `dbs_reference`, not against the candidate's id. The
  workflow has no way to say that, so the correlation lives here instead:
  `find_by_reference/1` is the lookup a declarative wait state would own.

  What the workflow would say if it could — see
  https://github.com/team-alembic/ash_workflow/issues/61:

      step :background_check do
        wait_for :dbs_result, correlate_on: :dbs_reference
      end

  Two things are missing while it lives here. Nothing verifies that
  `:dbs_reference` is a correlation key, so nothing requires it to be uniquely
  indexed. And a redelivered result finds the candidate already moved on, which
  arrives as `Ash.Error.Invalid` rather than as a recognised duplicate, so
  `return_result/2` has to decide what a repeat means.
  """

  require Ash.Query

  alias AshWorkflowDemo.ATS
  alias AshWorkflowDemo.ATS.Candidate
  alias AshWorkflowDemo.ATS.Candidate.DbsOffences

  @type result :: :clear | :flagged

  @doc """
  Returns every candidate the bureau currently owes a result on.
  """
  @spec pending() :: [Candidate.t()]
  def pending do
    Candidate
    |> Ash.Query.filter(state == :background_check)
    |> Ash.Query.sort(state_entered_at: :asc)
    |> Ash.read!(authorize?: false)
    |> Map.fetch!(:results)
  end

  @doc """
  Finds the candidate a reference belongs to.

  The correlation key. A declarative wait state would do this, and would know
  the attribute it was doing it on.
  """
  @spec find_by_reference(String.t()) :: {:ok, Candidate.t()} | :error
  def find_by_reference(reference) when is_binary(reference) do
    Candidate
    |> Ash.Query.filter(dbs_reference == ^reference)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> :error
      {:ok, candidate} -> {:ok, candidate}
      {:error, _} -> :error
    end
  end

  @doc """
  Applies a bureau result to whichever candidate holds the reference.

  Returns `{:ok, candidate}` on success, `:already_returned` when the candidate
  has already left `:background_check`, and `:unknown_reference` when nothing
  holds the reference. The middle case only exists because webhooks redeliver:
  the bureau is entitled to send the same result twice, and the second one is
  not an error on its part.
  """
  @spec return_result(String.t(), result(), String.t() | nil) ::
          {:ok, Candidate.t()} | :already_returned | :unknown_reference
  def return_result(reference, result, offence \\ nil) do
    case find_by_reference(reference) do
      :error ->
        :unknown_reference

      {:ok, %{state: :background_check} = candidate} ->
        apply_result(candidate, result, offence)

      {:ok, _candidate} ->
        :already_returned
    end
  end

  defp apply_result(candidate, :clear, _offence) do
    {:ok, ATS.dbs_clear!(candidate, %{}, authorize?: false)}
  end

  defp apply_result(candidate, :flagged, offence) do
    offence = offence || DbsOffences.random()

    {:ok, ATS.dbs_flag!(candidate, %{dbs_offence: offence}, authorize?: false)}
  end

  @doc """
  A plausible-looking bureau reference. Generated when the check is opened.
  """
  @spec generate_reference() :: String.t()
  def generate_reference do
    digits = 4 |> :crypto.strong_rand_bytes() |> Base.encode16() |> String.slice(0, 6)

    "DBS-#{digits}"
  end
end
