defmodule AshWorkflow do
  @moduledoc """
  Declarative workflow orchestration for Ash Framework.

  Define multi-step workflows that combine human actions, background jobs,
  and time-based deadlines as a single DSL. Generates ash_state_machine
  states/transitions, ash_oban triggers, and Ash actions.
  """

  alias AshWorkflow.Entities

  @transition %Spark.Dsl.Entity{
    name: :transition,
    describe: "Declares a named transition from this manual step to another step.",
    target: Entities.Transition,
    args: [:name],
    schema: Entities.Transition.attribute_schema()
  }

  @timeout %Spark.Dsl.Entity{
    name: :timeout,
    describe: "Declares a time-based action or forced transition if the workflow stays in this step too long.",
    target: Entities.Timeout,
    args: [:name],
    schema: Entities.Timeout.attribute_schema()
  }

  @step %Spark.Dsl.Entity{
    name: :step,
    describe: "Declares a step in the workflow. Each step becomes a state in the generated state machine.",
    target: Entities.Step,
    args: [:name],
    schema: Entities.Step.attribute_schema(),
    imports: [AshWorkflow.Checks],
    entities: [
      transitions: [@transition],
      timeouts: [@timeout]
    ]
  }

  @workflow %Spark.Dsl.Section{
    name: :workflow,
    describe: "Define a workflow by declaring steps, transitions, and timeouts.",
    schema: [],
    entities: [@step]
  }

  use Spark.Dsl.Extension,
    sections: [@workflow],
    add_extensions: [AshStateMachine, AshOban],
    transformers: [
      AshWorkflow.Transformers.AddAttributes,
      AshWorkflow.Transformers.AddStateMachine,
      AshWorkflow.Transformers.AddActions,
      AshWorkflow.Transformers.AddObanTriggers,
      AshWorkflow.Transformers.AddPolicies,
      AshWorkflow.Transformers.AddCodeInterface
    ],
    verifiers: [AshWorkflow.Verifiers.ValidateWorkflow]
end
