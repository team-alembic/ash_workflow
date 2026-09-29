defmodule AshWorkflow.RefuseStaleTransitionsTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Changes.StaleRecord
  alias AshWorkflow.Transformers.AddActions
  alias AshWorkflowTest.Reviewer
  alias AshWorkflowTest.SimpleDataLayerWorkflow
  alias AshWorkflowTest.StaleTransitionWorkflow

  defp create(attrs \\ %{}) do
    StaleTransitionWorkflow.create!(Map.merge(%{title: "candidate"}, attrs))
  end

  defp reload(record), do: Ash.get!(StaleTransitionWorkflow, record.id)

  defp stale_record_error?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%StaleRecord{}, &1))

  defp stale_record_error?(_error), do: false

  defp timeout_action(step_name, timeout_name) do
    step = AshWorkflow.Info.step(StaleTransitionWorkflow, step_name)
    timeout = Enum.find(step.timeouts, &(&1.name == timeout_name))
    AddActions.timeout_action_name(step, timeout)
  end

  test "refuses a transition from a copy loaded before the record changed step" do
    stale = create()
    Ash.update!(stale, action: :reject)

    assert {:error, error} = Ash.update(stale, action: :advance)
    assert stale_record_error?(error)
    assert reload(stale).state == :rejected
  end

  test "refuses a transition from a copy loaded before an attribute a route reads changed" do
    stale = create(%{path_type: :agency})
    Ash.update!(stale, %{path_type: :family}, action: :classify)

    assert {:error, error} = Ash.update(stale, action: :advance)
    assert stale_record_error?(error)
    assert %{state: :screening, path_type: :family} = reload(stale)
  end

  test "pins a nil attribute, so setting it makes the copy stale" do
    stale = create()
    Ash.update!(stale, %{path_type: :family}, action: :classify)

    assert {:error, error} = Ash.update(stale, action: :advance)
    assert stale_record_error?(error)
    assert reload(stale).state == :screening
  end

  test "moves a fresh record" do
    record = create(%{path_type: :family})

    assert Ash.update!(record, action: :advance).state == :compliance
    assert reload(record).state == :compliance
  end

  test "moves a copy whose only change since loading is to an attribute no route reads" do
    copy = create()
    Ash.update!(copy, %{note: "called back"}, action: :edit_note)

    assert Ash.update!(copy, action: :advance).state == :interviewing
    assert %{state: :interviewing, note: "called back"} = reload(copy)
  end

  test "does not pin a value read through a relationship" do
    sponsor = Reviewer.create!(%{name: "Fast"})
    copy = create(%{sponsor_id: sponsor.id}) |> Ash.load!(:sponsor)
    Ash.update!(sponsor, %{name: "Slow"}, action: :rename)

    assert Ash.update!(copy, action: :advance).state == :fast_track
  end

  test "refuses the second of two transitions from the same loaded copy, on the atomic path" do
    copy = create()

    assert {:ok, %{state: :interviewing}} = Ash.update(copy, action: :advance)
    assert {:error, error} = Ash.update(copy, action: :reject)
    assert stale_record_error?(error)
    assert reload(copy).state == :interviewing
  end

  test "refuses an undo from a copy loaded before the transition it would reverse" do
    stale = create() |> Ash.update!(action: :reject)
    stale |> Ash.update!(action: :undo) |> Ash.update!(action: :advance)

    # The head row is now `advance`, whose rewind to `screening` is one `rejected` may also take.
    assert {:error, error} = Ash.update(stale, action: :undo)
    assert stale_record_error?(error)
    assert reload(stale).state == :interviewing
  end

  test "undoes a fresh record" do
    rejected = create() |> Ash.update!(action: :reject)

    assert Ash.update!(rejected, action: :undo).state == :screening
  end

  test "leaves a timeout to the state machine, which refuses it from a step the record left" do
    stale = create()
    Ash.update!(stale, action: :reject)

    assert {:error, error} = Ash.update(stale, action: timeout_action(:screening, :expire))
    refute stale_record_error?(error)
    assert reload(stale).state == :rejected
  end

  test "leaves an automatic step's action to the state machine" do
    stale = create(%{path_type: :family}) |> Ash.update!(action: :advance)
    Ash.update!(stale, action: :run_checks)

    assert {:error, error} = Ash.update(stale, action: :run_checks)
    refute stale_record_error?(error)
    assert reload(stale).state == :done
  end

  test "pins nothing on a data layer that cannot filter an update" do
    copy = Ash.create!(SimpleDataLayerWorkflow, %{}, action: :create)
    Ash.update!(copy, action: :advance)

    assert Ash.update!(copy, action: :reject).state == :rejected
  end
end
