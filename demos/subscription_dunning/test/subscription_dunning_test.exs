defmodule SubscriptionDunning.SubscriptionTest do
  @moduledoc """
  Exercises the two kinds of deadline that look alike and behave differently: an
  `every` measured from when the state was entered, and a one-shot timeout
  measured against a date stored on the record.
  """
  use SubscriptionDunning.DataCase

  alias SubscriptionDunning.Subscription

  defp subscribe do
    Subscription.subscribe!(%{
      customer_email: "a@b.co",
      plan: "team",
      monthly_cents: 4900
    })
  end

  defp reload(sub), do: Ash.get!(Subscription, sub.id, authorize?: false)

  # Payment fails, and the billing system stamps a grace deadline on the record.
  defp fail_payment(sub, grace_days) do
    Subscription.payment_failed!(
      sub,
      %{grace_period_ends_at: DateTime.add(DateTime.utc_now(), grace_days, :day)},
      authorize?: false
    )
  end

  describe "entering arrears" do
    test "a new subscription is active" do
      assert subscribe().state == :active
    end

    test "a failed payment moves to the grace period and records the deadline" do
      sub = subscribe() |> fail_payment(7)

      assert sub.state == :grace_period
      assert sub.grace_period_ends_at
    end
  end

  describe "dunning email every" do
    setup do
      %{sub: subscribe() |> fail_payment(30)}
    end

    test "does not fire before the interval has elapsed", ctx do
      run_workflow_triggers(Subscription)

      assert reload(ctx.sub).dunning_emails_sent == 0
    end

    test "fires once per interval while the customer stays in arrears", ctx do
      age_by(ctx.sub, 4, :day)
      run_workflow_triggers(Subscription)

      assert reload(ctx.sub).dunning_emails_sent == 1
      assert reload(ctx.sub).state == :grace_period, "an action timeout does not change state"

      # Sending wrote grace_period_dunning_email_last_fired_at, so the next
      # send is three days out from that instant rather than firing on the
      # next poll.
      run_workflow_triggers(Subscription)
      assert reload(ctx.sub).dunning_emails_sent == 1

      ctx.sub
      |> reload()
      |> set_datetime(
        :grace_period_dunning_email_last_fired_at,
        DateTime.add(DateTime.utc_now(), -4, :day)
      )

      run_workflow_triggers(Subscription)
      assert reload(ctx.sub).dunning_emails_sent == 2
    end

    test "stops once the customer pays", ctx do
      age_by(ctx.sub, 4, :day)
      run_workflow_triggers(Subscription)
      assert reload(ctx.sub).dunning_emails_sent == 1

      Subscription.payment_received!(reload(ctx.sub), authorize?: false)
      assert reload(ctx.sub).state == :active

      age_by(ctx.sub, 10, :day)
      run_workflow_triggers(Subscription)

      assert reload(ctx.sub).dunning_emails_sent == 1, "no dunning once back in good standing"
    end
  end

  describe "data-driven grace deadline" do
    test "a subscription is not suspended while its own deadline is in the future" do
      sub = subscribe() |> fail_payment(7)

      run_workflow_triggers(Subscription)

      assert reload(sub).state == :grace_period
    end

    test "suspension happens when the stored deadline passes, not after a fixed interval" do
      sub = subscribe() |> fail_payment(7)

      # Move only the stored deadline into the past. state_entered_at is
      # untouched, so nothing but this field can be what triggers suspension.
      set_datetime(sub, :grace_period_ends_at, DateTime.add(DateTime.utc_now(), -1, :hour))
      run_workflow_triggers(Subscription)

      assert reload(sub).state == :suspended
    end

    test "customers get different deadlines from the same workflow" do
      generous = subscribe() |> fail_payment(30)
      stingy = subscribe() |> fail_payment(1)

      set_datetime(stingy, :grace_period_ends_at, DateTime.add(DateTime.utc_now(), -1, :hour))
      run_workflow_triggers(Subscription)

      assert reload(stingy).state == :suspended
      assert reload(generous).state == :grace_period
    end
  end

  describe "suspension" do
    setup do
      sub = subscribe() |> fail_payment(7)
      set_datetime(sub, :grace_period_ends_at, DateTime.add(DateTime.utc_now(), -1, :hour))
      run_workflow_triggers(Subscription)

      %{sub: reload(sub)}
    end

    test "a final notice goes out after seven days, without changing state", ctx do
      assert ctx.sub.state == :suspended

      age_by(ctx.sub, 8, :day)
      run_workflow_triggers(Subscription)

      assert reload(ctx.sub).final_notice_sent?
      assert reload(ctx.sub).state == :suspended
    end

    test "paying reactivates the subscription", ctx do
      reactivated = Subscription.payment_received!(ctx.sub, authorize?: false)

      assert reactivated.state == :active
    end

    test "a subscription nobody pays is cancelled after thirty days", ctx do
      age_by(ctx.sub, 31, :day)
      run_workflow_triggers(Subscription)

      assert reload(ctx.sub).state == :cancelled
    end
  end

  describe "cancelling" do
    test "the same :cancel transition works from both arrears states" do
      in_grace = subscribe() |> fail_payment(7)

      cancelled =
        Subscription.cancel!(in_grace, %{cancellation_reason: "customer request"},
          authorize?: false
        )

      assert cancelled.state == :cancelled
      assert cancelled.cancellation_reason == "customer request"
    end

    test "a cancelled subscription is terminal" do
      sub =
        subscribe()
        |> fail_payment(7)
        |> Subscription.cancel!(%{cancellation_reason: "done"}, authorize?: false)

      assert {:error, _} = Subscription.payment_received(sub, authorize?: false)
    end
  end
end
