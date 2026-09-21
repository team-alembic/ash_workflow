defmodule AshWorkflow.Transformers.AddAttributesTest do
  @moduledoc """
  `state_entered_at` is the anchor every deadline on a step measures from, so a
  write from outside AshWorkflow moves all of them at once. It is declared
  `writable?: false` to stop that, and these tests pin down both halves of the
  guarantee: outside callers cannot set it through an action, and AshWorkflow
  still writes it on a transition.
  """
  use ExUnit.Case, async: true

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflowTest.LinearWorkflow

  @backdated ~U[2020-01-01 00:00:00.000000Z]

  test "state_entered_at is declared non-writable and public" do
    attribute = ResourceInfo.attribute(LinearWorkflow, :state_entered_at)

    refute attribute.writable?
    assert attribute.public?
  end

  test "a create action rejects state_entered_at as input" do
    assert_raise Ash.Error.Invalid, fn ->
      LinearWorkflow
      |> Ash.Changeset.for_create(:create, %{title: "one", state_entered_at: @backdated})
      |> Ash.create!()
    end
  end

  test "an update action rejects state_entered_at as input" do
    record = create!()

    assert_raise Ash.Error.Invalid, fn ->
      record
      |> Ash.Changeset.for_update(:do_processing, %{state_entered_at: @backdated})
      |> Ash.update!()
    end
  end

  test "force_change_attribute still reaches it, so backfilling stays possible" do
    record =
      LinearWorkflow
      |> Ash.Changeset.for_create(:create, %{title: "one"})
      |> Ash.Changeset.force_change_attribute(:state_entered_at, @backdated)
      |> Ash.create!()

    assert DateTime.compare(record.state_entered_at, @backdated) == :eq
  end

  test "AshWorkflow still writes it on a transition" do
    record =
      LinearWorkflow
      |> Ash.Changeset.for_create(:create, %{title: "one"})
      |> Ash.Changeset.force_change_attribute(:state_entered_at, @backdated)
      |> Ash.create!()

    transitioned =
      record
      |> Ash.Changeset.for_update(:do_processing, %{})
      |> Ash.update!()

    assert DateTime.compare(transitioned.state_entered_at, @backdated) == :gt
  end

  defp create!(attrs \\ %{title: "one"}) do
    LinearWorkflow
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!()
  end
end
