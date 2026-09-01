defmodule AshWorkflow do
  @moduledoc """
  Declarative workflow orchestration for Ash Framework.

  Define multi-step workflows that combine human actions, background jobs,
  and time-based deadlines as a single DSL. Generates ash_state_machine
  states/transitions, ash_oban triggers, and Ash actions.
  """

  alias AshWorkflow.Entities

  @route %Spark.Dsl.Entity{
    name: :route,
    describe: "A conditional target for a transition. Evaluated at runtime.",
    target: Entities.Route,
    imports: [Ash.Expr],
    args: [:to],
    schema: Entities.Route.attribute_schema()
  }

  @transition %Spark.Dsl.Entity{
    name: :transition,
    describe: "Declares a named transition from this manual step to another step.",
    target: Entities.Transition,
    args: [:name],
    schema: Entities.Transition.attribute_schema(),
    entities: [
      routes: [@route]
    ]
  }

  @timeout %Spark.Dsl.Entity{
    name: :timeout,
    describe:
      "Declares a time-based action or forced transition if the workflow stays in this step too long.",
    target: Entities.Timeout,
    args: [:name],
    schema: Entities.Timeout.attribute_schema()
  }

  @belongs_to_actor %Spark.Dsl.Entity{
    name: :belongs_to_actor,
    describe: "Configures actor capture on the transition log.",
    target: Entities.BelongsToActor,
    args: [:name, :destination],
    schema: Entities.BelongsToActor.attribute_schema()
  }

  @transition_log %Spark.Dsl.Entity{
    name: :transition_log,
    describe: """
    Declares an opt-in transition log resource that records one row per
    workflow event. See `AshWorkflow.Entities.TransitionLog`.
    """,
    target: Entities.TransitionLog,
    args: [:resource],
    schema: Entities.TransitionLog.attribute_schema(),
    entities: [
      belongs_to_actor: [@belongs_to_actor]
    ]
  }

  @step %Spark.Dsl.Entity{
    name: :step,
    describe:
      "Declares a step in the workflow. Each step becomes a state in the generated state machine.",
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
    schema: [
      queue: [
        type: :atom,
        default: :workflow,
        doc: "The Oban queue to use for all generated triggers. Defaults to :workflow."
      ],
      check_interval: [
        type: :string,
        default: "* * * * *",
        doc: """
        Oban cron expression controlling how often every generated trigger on
        this resource polls — both automatic steps and timeouts. Defaults to
        every minute.

        Each automatic step and each timeout gets its own scheduler, and every
        scheduler runs a query on every tick, so this multiplies: a resource
        with four automatic steps and four timeouts polls eight times a minute
        at the default. Raise it for workflows measured in days, and override
        individual timeouts with `check_interval` on the timeout itself.
        """
      ]
    ],
    entities: [@step, @transition_log]
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
      AshWorkflow.Transformers.AddCodeInterface,
      AshWorkflow.Transformers.AddCalculations
    ],
    verifiers: [
      AshWorkflow.Verifiers.ValidateWorkflow,
      AshWorkflow.Verifiers.ValidateTimeoutFields,
      AshWorkflow.Verifiers.ValidateTransitionLog
    ]
end
