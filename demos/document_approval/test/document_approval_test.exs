defmodule DocumentApproval.DocumentTest do
  @moduledoc """
  The point of this demo is the two-admin sign-off: `:approve` is one action
  whose destination is decided at runtime, so calling it once deliberately does
  not finish the job.
  """
  use DocumentApproval.DataCase

  alias DocumentApproval.Document

  defp admin(name), do: %{id: Ash.UUID.generate(), name: name, role: :admin}

  defp submit(attrs \\ %{}) do
    Document.submit!(
      Map.merge(
        %{title: "Q3 plan", body: "We should ship this in Q3.", author_email: "a@b.co"},
        attrs
      )
    )
  end

  defp reach_review(attrs \\ %{}) do
    document = submit(attrs)
    run_workflow_triggers(Document)
    reload(document)
  end

  defp reload(document), do: Ash.get!(Document, document.id, authorize?: false)

  describe "reaching review" do
    test "a submitted document starts in the validating step" do
      assert submit().state == :validating
    end

    test "validation runs automatically and hands over to the reviewers" do
      document = reach_review()

      assert document.state == :in_review
      assert document.first_approver_id == nil
    end

    test "a document that fails validation routes to on_error" do
      assert reach_review(%{body: "TBD"}).state == :validation_failed
    end
  end

  describe "two-admin sign-off" do
    setup do
      %{document: reach_review(), alice: admin("alice"), bob: admin("bob")}
    end

    test "the first approval records the approver but does not advance", ctx do
      approved_once = Document.approve!(ctx.document, actor: ctx.alice)

      assert approved_once.state == :in_review, "one signature is not enough"
      assert approved_once.first_approver_id == ctx.alice.id
      assert approved_once.second_approver_id == nil
    end

    test "a second, different admin completes the sign-off", ctx do
      ctx.document
      |> Document.approve!(actor: ctx.alice)
      |> Document.approve!(actor: ctx.bob)

      document = reload(ctx.document)

      assert document.state == :approved
      assert document.first_approver_id == ctx.alice.id
      assert document.second_approver_id == ctx.bob.id
    end

    test "the same admin cannot supply both signatures", ctx do
      once = Document.approve!(ctx.document, actor: ctx.alice)

      assert {:error, error} = Document.approve(once, actor: ctx.alice)
      assert Exception.message(error) =~ "already approved"

      assert reload(ctx.document).state == :in_review
    end

    test "approving is refused without an actor", ctx do
      assert {:error, _} = Document.approve(ctx.document, authorize?: false)
    end

    test "only admins may approve", ctx do
      author = %{id: Ash.UUID.generate(), name: "carol", role: :author}

      assert {:error, error} = Document.approve(ctx.document, actor: author)
      assert Exception.message(error) =~ "forbidden"
    end
  end

  describe "rejection" do
    test "a single admin can reject outright" do
      document = reach_review()

      rejected =
        Document.reject!(document, %{rejection_reason: "out of date"}, actor: admin("alice"))

      assert rejected.state == :rejected
      assert rejected.rejection_reason == "out of date"
    end
  end

  describe "timeouts" do
    setup do
      %{document: reach_review()}
    end

    test "the nudge every fires once per interval while review is pending", ctx do
      age_by(ctx.document, 3, :day)
      run_workflow_triggers(Document)
      assert reload(ctx.document).nudges_sent == 1

      # An every resets state_entered_at, so the next nudge needs the
      # clock moved on again rather than firing immediately.
      run_workflow_triggers(Document)
      assert reload(ctx.document).nudges_sent == 1

      age_by(ctx.document, 3, :day)
      run_workflow_triggers(Document)
      assert reload(ctx.document).nudges_sent == 2
    end

    test "a document nobody reviews eventually expires", ctx do
      age_by(ctx.document, 15, :day)
      run_workflow_triggers(Document)

      assert reload(ctx.document).state == :expired
    end

    test "an approved document is not expired by the timeout", ctx do
      ctx.document
      |> Document.approve!(actor: admin("alice"))
      |> Document.approve!(actor: admin("bob"))

      age_by(ctx.document, 15, :day)
      run_workflow_triggers(Document)

      assert reload(ctx.document).state == :approved
    end
  end
end
