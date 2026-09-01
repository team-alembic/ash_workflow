defmodule AshWorkflow.Transformers.ReadActionPaginationTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflowTest.LinearWorkflow
  alias AshWorkflowTest.LoggedWorkflow

  describe "the generated read action" do
    test "enables keyset pagination, which ash_oban requires" do
      pagination = ResourceInfo.action(LinearWorkflow, :read).pagination

      assert pagination.keyset?
      assert pagination.default_limit == 100
    end

    test "paginates by default, so existing callers keep receiving a page" do
      pagination = ResourceInfo.action(LinearWorkflow, :read).pagination

      assert pagination.paginate_by_default?

      {:ok, _} = LoggedWorkflow.create(%{title: "paginated by default"})

      assert %Ash.Page.Keyset{} = Ash.read!(LoggedWorkflow, authorize?: false)
    end

    test "does not require pagination, so callers can opt out with page: false" do
      pagination = ResourceInfo.action(LinearWorkflow, :read).pagination

      refute pagination.required?

      {:ok, record} = LoggedWorkflow.create(%{title: "opted out"})

      records = Ash.read!(LoggedWorkflow, page: false, authorize?: false)

      assert is_list(records)
      assert record.id in Enum.map(records, & &1.id)
    end
  end
end
