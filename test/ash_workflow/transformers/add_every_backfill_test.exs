defmodule AshWorkflow.Transformers.AddEveryBackfillTest do
  @moduledoc """
  A row written before an `every`'s column existed, or before it started
  repeating, is `nil` for that column — indistinguishable from a genuine
  never-fired record without this migration, which is exactly why it exists:
  without it, every existing row fires at once the moment this ships.
  """
  use ExUnit.Case, async: true

  alias AshPostgres.DataLayer.Info, as: PostgresInfo

  defp statement(resource, name) do
    resource
    |> PostgresInfo.custom_statements()
    |> Enum.find(&(&1.name == name))
  end

  describe "AshPostgres resources" do
    test "generate one backfill statement per every, named after its column" do
      statement =
        statement(
          AshWorkflowTest.Postgres.EveryUntilWorkflow,
          :backfill_waiting_reminder_last_fired_at
        )

      assert statement

      assert statement.up =~
               "UPDATE every_until_workflows SET waiting_reminder_last_fired_at = state_entered_at;"

      assert statement.down =~ "SELECT 1;"
    end
  end

  describe "other data layers" do
    test "generate no backfill statements, since custom_statements is a Postgres-only DSL section" do
      assert PostgresInfo.custom_statements(AshWorkflowTest.EveryUntilWorkflow) == []
    end
  end
end
