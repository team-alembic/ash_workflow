defmodule AshWorkflow.Charts.FormatTest do
  use ExUnit.Case, async: true

  require Ash.Expr

  alias AshWorkflow.Charts.Format
  alias AshWorkflow.Entities.Retry
  alias AshWorkflow.Entities.Undo

  describe "duration/1" do
    @units [seconds: "second", minutes: "minute", hours: "hour", days: "day"]

    for {unit, singular} <- @units do
      test "uses the singular for one #{singular}" do
        assert Format.duration({1, unquote(unit)}) == "1 #{unquote(singular)}"
      end

      test "uses the plural for more than one #{singular}" do
        assert Format.duration({2, unquote(unit)}) == "2 #{unquote(unit)}"
        assert Format.duration({90, unquote(unit)}) == "90 #{unquote(unit)}"
      end
    end
  end

  describe "deadline/1" do
    test "a fire_after timeout measured from state_entered_at" do
      timeout = %{fire_at: nil, fire_after: {7, :days}, field: :state_entered_at}
      assert Format.deadline(timeout) == "after 7 days"
    end

    test "a fire_after timeout measured from another field names the field" do
      timeout = %{fire_at: nil, fire_after: {3, :days}, field: :last_session_date}
      assert Format.deadline(timeout) == "3 days after last_session_date"
    end

    test "a nil field means state_entered_at" do
      timeout = %{fire_at: nil, fire_after: {7, :days}, field: nil}
      assert Format.deadline(timeout) == "after 7 days"
    end

    test "a fire_at timeout names the field that holds the instant" do
      timeout = %{fire_at: :next_check_at, fire_after: nil, field: nil}
      assert Format.deadline(timeout) == "at next_check_at"
    end
  end

  describe "every/1" do
    test "without until" do
      assert Format.every(%{interval: {2, :days}, until: nil}) == "every 2 days"
    end

    test "with until" do
      assert Format.every(%{interval: {1, :hours}, until: {3, :hours}}) ==
               "every 1 hour for 3 hours"
    end
  end

  describe "undo/1" do
    test "without a window" do
      assert Format.undo(%Undo{within: nil}) == "undo"
    end

    test "with a window" do
      assert Format.undo(%Undo{within: {1, :hours}}) == "undo within 1 hour"
    end
  end

  describe "retry/1" do
    test "no retry block and a single attempt have no label" do
      assert Format.retry(nil) == nil
      assert Format.retry(%Retry{max_attempts: 1}) == nil
    end

    test "a fixed backoff" do
      assert Format.retry(%Retry{max_attempts: 3, backoff: {10, :seconds}}) ==
               "3 attempts, 10 seconds apart"
    end

    test "an exponential backoff" do
      assert Format.retry(%Retry{max_attempts: 5, backoff: :exponential}) ==
               "5 attempts, exponential backoff"
    end
  end

  describe "policy/1" do
    test "uses the check's own describe/1" do
      check = {Ash.Policy.Check.ActorAttributeEquals, attribute: :role, value: :reviewer}
      assert Format.policy(check) == "actor.role == :reviewer"
    end

    test "falls back to inspect for a module without describe/1" do
      assert Format.policy({String, []}) == "{String, []}"
    end

    test "a bare check module, as actor_present() returns" do
      assert Format.policy(Ash.Policy.Check.ActorPresent) == "actor is present"
    end

    test "writes an expression policy as text" do
      assert Format.policy(Ash.Expr.expr(status == :open)) == "status == :open"
    end

    test "writes an actor template as the DSL does" do
      assert Format.policy(Ash.Expr.expr(^Ash.Expr.actor(:role) == :reviewer)) ==
               "^actor(:role) == :reviewer"
    end

    test "no policy has no label" do
      assert Format.policy(nil) == nil
    end
  end

  describe "condition/1" do
    test "writes an Ash expression as text" do
      assert Format.condition(Ash.Expr.expr(score < 3)) == "score < 3"
    end

    test "writes an argument template as the DSL does" do
      assert Format.condition(Ash.Expr.expr(amount > ^Ash.Expr.arg(:limit))) ==
               "amount > ^arg(:limit)"
    end

    test "writes the tenant template as the DSL does" do
      assert Format.condition(Ash.Expr.expr(tenant_id == ^Ash.Expr.tenant())) ==
               "tenant_id == ^tenant()"
    end

    test "a route without a condition has none" do
      assert Format.condition(nil) == nil
    end
  end
end
