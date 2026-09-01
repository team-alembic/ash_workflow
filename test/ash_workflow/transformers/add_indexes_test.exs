defmodule AshWorkflow.Transformers.AddIndexesTest do
  @moduledoc """
  The generated triggers filter on `state`, and timeouts additionally on their
  `field`. These indexes are what keep a poll that finds nothing from being a
  sequential scan, so their presence is worth asserting directly.
  """
  use ExUnit.Case, async: true

  alias AshPostgres.DataLayer.Info, as: PostgresInfo
  alias AshWorkflow.Info

  defp index_fields(resource) do
    resource
    |> PostgresInfo.custom_indexes()
    |> Enum.map(fn index -> Enum.map(index.fields, &to_string/1) end)
  end

  describe "recommended_indexes/1" do
    test "pairs state with state_entered_at for a default-field timeout" do
      assert [[:state, :state_entered_at]] =
               Info.recommended_indexes(AshWorkflowTest.TimeoutWorkflow)
    end

    test "pairs state with a custom timeout field" do
      assert [[:state, :last_session_date]] =
               Info.recommended_indexes(AshWorkflowTest.FieldTimeoutWorkflow)
    end

    test "omits calculation-backed fields, which are not columns" do
      refute Enum.any?(
               Info.recommended_indexes(AshWorkflowTest.ExprCalcTimeoutWorkflow),
               &(&1 == [:state, :grace_period_start])
             )
    end

    test "falls back to state alone when a workflow declares no timeouts" do
      assert [[:state]] = Info.recommended_indexes(AshWorkflowTest.LinearWorkflow)
    end

    test "deduplicates fields shared across steps" do
      indexes = Info.recommended_indexes(AshWorkflowTest.Postgres.ApprovalWorkflow)

      assert indexes == Enum.uniq(indexes)
    end
  end

  describe "AshPostgres resources" do
    test "gain an index per recommended field" do
      fields = index_fields(AshWorkflowTest.Postgres.ApprovalWorkflow)

      for recommended <- Info.recommended_indexes(AshWorkflowTest.Postgres.ApprovalWorkflow) do
        assert Enum.map(recommended, &to_string/1) in fields
      end
    end

    test "name generated indexes so they are identifiable in migrations" do
      names =
        AshWorkflowTest.Postgres.ApprovalWorkflow
        |> PostgresInfo.custom_indexes()
        |> Enum.map(& &1.name)

      assert Enum.any?(names, &String.starts_with?(to_string(&1), "ash_workflow_"))
    end
  end

  describe "opting out" do
    test "generate_indexes? false adds nothing" do
      assert [] == index_fields(AshWorkflowTest.Postgres.NoIndexWorkflow)
    end

    test "a user-declared index on the same fields wins" do
      indexes = PostgresInfo.custom_indexes(AshWorkflowTest.Postgres.OwnIndexWorkflow)

      state_indexes =
        Enum.filter(indexes, fn index ->
          Enum.map(index.fields, &to_string/1) == ["state", "state_entered_at"]
        end)

      assert [index] = state_indexes
      assert index.unique
    end
  end
end
