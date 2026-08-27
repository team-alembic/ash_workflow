defmodule AshWorkflow.GeneratedReadActionTest do
  @moduledoc """
  A workflow with automatic steps generates Oban triggers, and ash_oban needs a
  primary read action to drive them. The extension supplies one when the
  resource has none — without treading on a read action the resource already
  defines.
  """
  use ExUnit.Case, async: true

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflowTest.ApprovalWorkflow
  alias AshWorkflowTest.NonPrimaryReadWorkflow

  defp reads(resource) do
    resource |> ResourceInfo.actions() |> Enum.filter(&(&1.type == :read))
  end

  describe "when the resource has no read action" do
    test "a primary :read is generated" do
      assert %{name: :read, primary?: true} =
               ResourceInfo.primary_action(ApprovalWorkflow, :read)
    end

    test "it paginates, which ash_oban's triggers require" do
      read = ResourceInfo.primary_action(ApprovalWorkflow, :read)

      assert read.pagination.keyset?
    end
  end

  describe "when the resource declares defaults [:read]" do
    # This is the shape that broke the build on Elixir 1.15 through 1.18: the
    # defaults are expanded by the same Ash transformer that marks primaries, so
    # running before it meant seeing no read action and generating a second one.
    test "the resource keeps its own :read, and nothing extra is generated" do
      assert [%{name: :read, primary?: true}] = reads(AshWorkflowTest.Postgres.ApprovalWorkflow)
    end
  end

  describe "when the resource already has a read named :read that is not primary" do
    test "the generated action does not reuse the name" do
      names = Enum.map(reads(NonPrimaryReadWorkflow), & &1.name)

      assert length(Enum.filter(names, &(&1 == :read))) == 1,
             "generated a second action named :read, which fails to compile as " <>
               "\"Multiple actions with the name `read` defined\" — got #{inspect(names)}"
    end

    test "no two read actions share a name" do
      names = Enum.map(reads(NonPrimaryReadWorkflow), & &1.name)

      assert names == Enum.uniq(names)
    end

    test "a primary read still exists, so ash_oban's triggers can run" do
      assert %{primary?: true} = ResourceInfo.primary_action(NonPrimaryReadWorkflow, :read)
    end

    test "the resource's own :read action is left alone" do
      assert Enum.find(reads(NonPrimaryReadWorkflow), &(&1.name == :read))
    end
  end
end
