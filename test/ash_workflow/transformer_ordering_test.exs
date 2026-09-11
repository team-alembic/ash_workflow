defmodule AshWorkflow.TransformerOrderingTest do
  @moduledoc """
  AshWorkflow builds AshOban triggers and an ash_state_machine state machine, and
  both of those extensions finish the job in transformers of their own. Our
  transformers therefore declare `before?/1` against them, and everything
  downstream — trigger queues, read actions, the `state` attribute's default —
  depends on those declarations being honoured.

  Spark resolves the declarations by topological sort, and that sort degrades
  when the graph it is given contains a cycle: constraints unrelated to the cycle
  come out reversed. A cycle can be introduced by a transformer in *any*
  extension on the resource, including ones we do not depend on, so this is not
  a contract we can uphold locally — only assert.

  These tests pin the ordering itself and the facts that depend on it, so the
  failure surfaces here rather than as `attribute state is required` from an
  unrelated create.

  A broken ordering can also stop `test/test_helper.exs` from booting, in which
  case no test in the suite reports anything. Run
  `MIX_ENV=test mix run bin/check-transformer-ordering.exs` for the same checks
  without ExUnit.
  """
  use ExUnit.Case, async: true

  @resource AshWorkflowTest.Workflow

  test "every `before?` we declare against another extension is honoured" do
    case AshWorkflowTest.TransformerContracts.violations(@resource) do
      [] ->
        :ok

      violations ->
        flunk(Enum.map_join(violations, "\n", &AshWorkflowTest.TransformerContracts.explain/1))
    end
  end

  describe "facts that depend on that ordering" do
    test "every generated trigger has its AshOban defaults filled in" do
      for trigger <- AshOban.Info.oban_triggers(@resource) do
        assert trigger.read_action,
               "trigger #{inspect(trigger.name)} has no read_action — AshOban.Transformers.SetDefaults did not see it"

        assert trigger.scheduler_queue,
               "trigger #{inspect(trigger.name)} has no scheduler_queue — AshOban.Transformers.SetDefaults did not see it"
      end
    end

    test "the state attribute defaults to the workflow's initial step" do
      attribute = Ash.Resource.Info.attribute(@resource, :state)
      {:ok, initial} = AshStateMachine.Info.state_machine_default_initial_state(@resource)

      assert attribute.default == initial,
             "expected `state` to default to #{inspect(initial)}, got #{inspect(attribute.default)}"
    end
  end
end
