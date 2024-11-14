defmodule AshWorkflowTest do
  alias AshWorkflowTest.Step1
  use ExUnit.Case
  doctest AshWorkflow

  test "greets the world" do
    {:ok, workflow} = AshWorkflowTest.Workflow.start()

    assert workflow.current_step_index == 0

    {:ok, workflow} =
      workflow
      |> Ash.load(:steps)

    assert Enum.count(dbg(workflow.steps)) == 2

    {:ok, workflow} =
      workflow
      |> AshWorkflowTest.Workflow.next(%{params: %{name: "Barnabas"}})

    assert workflow.current_step_index == 1


    {:ok, steps} =
    Step1
    |> Ash.Query.for_read(:read)
    |> Ash.read()


    assert Enum.count(dbg(steps)) == 1
    [step] = steps
    assert step.name == "Barnabas"
  end

end
