defmodule AshWorkflow.ConditionalTransitionTest do
  use ExUnit.Case

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshStateMachine.Info, as: StateMachineInfo
  alias AshWorkflow.Entities.{Route, Step, Transition}
  alias AshWorkflow.Verifiers.ValidateWorkflow

  defp build_dsl(steps) do
    %{[:workflow] => %{entities: steps}}
  end

  defp step(name, opts \\ []) do
    %Step{
      name: name,
      action: opts[:action],
      terminal: opts[:terminal] || false,
      on_success: opts[:on_success] || [],
      on_error: opts[:on_error],
      policy: opts[:policy],
      transitions: opts[:transitions] || [],
      timeouts: opts[:timeouts] || []
    }
  end

  defp transition(name, opts) when is_list(opts) do
    %Transition{name: name, to: opts[:to], routes: opts[:routes] || []}
  end

  defp transition(name, to) when is_atom(to) do
    %Transition{name: name, to: to, routes: []}
  end

  defp route(to, condition) do
    %Route{to: to, when: condition}
  end

  describe "verifier: conditional transitions" do
    test "valid conditional transition passes" do
      dsl =
        build_dsl([
          step(:review,
            transitions: [
              transition(:complete,
                routes: [route(:path_a, true), route(:path_b, true)]
              ),
              transition(:reject, :rejected)
            ]
          ),
          step(:path_a, terminal: true),
          step(:path_b, terminal: true),
          step(:rejected, terminal: true)
        ])

      assert :ok = ValidateWorkflow.verify(dsl)
    end

    test "transition with both to and routes fails" do
      dsl =
        build_dsl([
          step(:review,
            transitions: [
              transition(:complete,
                to: :path_a,
                routes: [route(:path_b, true)]
              )
            ]
          ),
          step(:path_a, terminal: true),
          step(:path_b, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "has both `to` and conditional routes"
    end

    test "transition with neither to nor routes fails" do
      dsl =
        build_dsl([
          step(:review,
            transitions: [transition(:complete, [])]
          ),
          step(:done, terminal: true)
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "must have either `to` or conditional routes"
    end

    test "conditional route referencing unknown step fails" do
      dsl =
        build_dsl([
          step(:review,
            transitions: [
              transition(:complete,
                routes: [route(:nonexistent, true)]
              )
            ]
          )
        ])

      assert {:error, %Spark.Error.DslError{message: message}} = ValidateWorkflow.verify(dsl)
      assert message =~ "references unknown step :nonexistent"
    end

    test "conditional targets are included in reachability" do
      dsl =
        build_dsl([
          step(:review,
            transitions: [
              transition(:complete,
                routes: [route(:path_a, true), route(:path_b, true)]
              )
            ]
          ),
          step(:path_a, terminal: true),
          step(:path_b, terminal: true)
        ])

      assert :ok = ValidateWorkflow.verify(dsl)
    end
  end

  describe "state machine generation" do
    test "conditional transition generates state machine transition with all targets" do
      transitions =
        StateMachineInfo.state_machine_transitions(AshWorkflowTest.ConditionalWorkflow)

      complete_transition =
        Enum.find(transitions, fn t -> t.action == :complete end)

      assert complete_transition
      assert :compliance in complete_transition.from
      assert :training in complete_transition.to
      assert :fast_track in complete_transition.to
    end

    test "all conditional targets are valid states" do
      states = StateMachineInfo.state_machine_all_states(AshWorkflowTest.ConditionalWorkflow)

      assert :training in states
      assert :fast_track in states
    end
  end

  describe "generated actions" do
    test "conditional transition generates an action" do
      action = ResourceInfo.action(AshWorkflowTest.ConditionalWorkflow, :complete)
      assert action
      assert action.type == :update
    end

    test "static transition on same step also generates an action" do
      action =
        ResourceInfo.action(AshWorkflowTest.ConditionalWorkflow, :reject_at_compliance)

      assert action
      assert action.type == :update
    end
  end

  describe "runtime conditional routing" do
    test "routes to first matching condition (full path)" do
      {:ok, workflow} =
        AshWorkflowTest.ConditionalWorkflow.create(%{title: "test", path_type: :full})

      assert workflow.state == :compliance

      {:ok, workflow} =
        Ash.update(workflow, action: :complete)

      assert workflow.state == :training
    end

    test "routes to second matching condition (abbreviated path)" do
      {:ok, workflow} =
        AshWorkflowTest.ConditionalWorkflow.create(%{title: "test", path_type: :abbreviated})

      assert workflow.state == :compliance

      {:ok, workflow} =
        Ash.update(workflow, action: :complete)

      assert workflow.state == :fast_track
    end

    test "returns error when no route matches" do
      {:ok, workflow} =
        AshWorkflowTest.FailingRouteWorkflow.create(%{title: "test", category: :unknown})

      assert workflow.state == :pending

      assert {:error, error} = Ash.update(workflow, action: :decide)
      assert Exception.message(error) =~ "No matching condition for transition :decide"
    end

    test "a route reads the input the same call accepted" do
      {:ok, workflow} =
        AshWorkflowTest.AcceptedRouteWorkflow.create(%{title: "test"})

      assert workflow.state == :review
      assert is_nil(workflow.decision)

      {:ok, workflow} =
        Ash.update(workflow, %{decision: :approve}, action: :decide)

      assert workflow.state == :approved
      assert workflow.decision == :approve
    end

    test "the same transition routes elsewhere on a different accepted value" do
      {:ok, workflow} =
        AshWorkflowTest.AcceptedRouteWorkflow.create(%{title: "test"})

      {:ok, workflow} =
        Ash.update(workflow, %{decision: :reject}, action: :decide)

      assert workflow.state == :rejected
    end

    test "an accepted value overrides the one already on the record" do
      {:ok, workflow} =
        AshWorkflowTest.AcceptedRouteWorkflow.create(%{title: "test", decision: :reject})

      {:ok, workflow} =
        Ash.update(workflow, %{decision: :approve}, action: :decide)

      assert workflow.state == :approved
    end

    test "a route reading an untouched attribute still sees the loaded record" do
      {:ok, workflow} =
        AshWorkflowTest.AcceptedRouteWorkflow.create(%{title: "test", priority: :urgent})

      {:ok, workflow} =
        Ash.update(workflow, %{decision: :reject}, action: :escalate)

      assert workflow.state == :approved
    end

    test "a route does not see an attribute the action's own change writes" do
      {:ok, workflow} =
        AshWorkflowTest.AcceptedRouteWorkflow.create(%{title: "test"})

      assert is_nil(workflow.signed_by)

      {:ok, workflow} = Ash.update(workflow, action: :sign_off)

      assert workflow.signed_by == "signer"
      assert workflow.state == :review
    end

    test "the second call routes on what the first call wrote" do
      {:ok, workflow} =
        AshWorkflowTest.AcceptedRouteWorkflow.create(%{title: "test"})

      {:ok, workflow} = Ash.update(workflow, action: :sign_off)
      {:ok, workflow} = Ash.update(workflow, action: :sign_off)

      assert workflow.state == :approved
    end

    test "static transition still works alongside conditional" do
      {:ok, workflow} =
        AshWorkflowTest.ConditionalWorkflow.create(%{title: "test", path_type: :full})

      {:ok, workflow} =
        Ash.update(workflow, action: :reject_at_compliance)

      assert workflow.state == :rejected
    end
  end
end
