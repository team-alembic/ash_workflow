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

  @on_success %Spark.Dsl.Entity{
    name: :on_success,
    describe:
      "Declares a step to transition to when this step's action succeeds, optionally " <>
        "guarded by a `when` condition. Repeatable: declare it more than once to fan out " <>
        "to different states depending on what the action computed. Entries are evaluated " <>
        "in declaration order, first match wins, against the record *after* the step's " <>
        "action has run. An entry with no `when` is unconditional and must be declared " <>
        "last, since it always matches and would otherwise shadow any entries after it.",
    target: Entities.Route,
    imports: [Ash.Expr],
    args: [:to],
    schema: [
      to: [
        type: :atom,
        required: true,
        doc: "The step to transition to."
      ],
      when: [
        type: :any,
        required: false,
        doc:
          "An Ash expression evaluated against the record after the action has run. " <>
            "Use `expr(attribute == value)`. Omit for an unconditional route."
      ]
    ]
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

  @undo %Spark.Dsl.Entity{
    name: :undo,
    describe: """
    Enables undo for this workflow. Requires a `transition_log`, and at least
    one transition marked `undoable?: true`. See `AshWorkflow.Entities.Undo`.
    """,
    target: Entities.Undo,
    imports: [AshWorkflow.Checks],
    schema: Entities.Undo.attribute_schema()
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
      timeouts: [@timeout],
      on_success: [@on_success]
    ]
  }

  @workflow %Spark.Dsl.Section{
    name: :workflow,
    describe: "Define a workflow by declaring steps, transitions, and timeouts.",
    schema: [
      state_attribute: [
        type: :atom,
        doc: """
        The attribute the workflow's current step is stored in. Defaults to
        `state`.

        AshWorkflow passes this down to `ash_state_machine`, so set it here
        rather than in the `state_machine` section. Use it when the resource
        already has a lifecycle column of its own, such as `status`.
        """
      ],
      scheduler: [
        type: {:custom, AshWorkflow.Scheduler, :validate, []},
        doc: """
        The module that decides when this workflow's automatic steps and
        timeouts run, optionally with its options:

            scheduler AshWorkflow.Scheduler.Oban
            scheduler {AshWorkflow.Scheduler.Oban, check_interval: "0 * * * *"}

        Defaults to the `:scheduler` application environment for `:ash_workflow`,
        and to `AshWorkflow.Scheduler.Oban` when that is unset.

        `AshWorkflow.Scheduler.Oban` requires the resource to also have the
        `AshOban` extension. AshWorkflow does not add it, so that a workflow
        using a scheduler unrelated to Oban does not carry the ash_oban DSL.

        See `AshWorkflow.Scheduler` for the behaviour an implementation
        satisfies.
        """
      ],
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
      ],
      generate_indexes?: [
        type: :boolean,
        default: true,
        doc: """
        Whether to add the composite indexes the generated triggers rely on.
        Only applies to resources using `AshPostgres.DataLayer`; other data
        layers ignore it.

        Every trigger filters on the state attribute, and every timeout also
        filters on its `field`, so without `(state, field)` indexes each poll
        is a sequential scan. Set to `false` if you manage these indexes yourself — a
        `custom_indexes` entry on the same fields already takes precedence.

        See `AshWorkflow.Info.recommended_indexes/1`.
        """
      ]
    ],
    entities: [@step, @transition_log, @undo]
  }

  use Spark.Dsl.Extension,
    sections: [@workflow],
    add_extensions: [AshStateMachine],
    transformers: [
      AshWorkflow.Transformers.AddAttributes,
      AshWorkflow.Transformers.AddStateMachine,
      AshWorkflow.Transformers.AddActions,
      AshWorkflow.Transformers.AddScheduler,
      AshWorkflow.Transformers.AddIndexes,
      AshWorkflow.Transformers.AddPolicies,
      AshWorkflow.Transformers.AddCodeInterface,
      AshWorkflow.Transformers.AddCalculations
    ],
    verifiers: [
      AshWorkflow.Verifiers.ValidateWorkflow,
      AshWorkflow.Verifiers.ValidateTimeoutFields,
      AshWorkflow.Verifiers.ValidateTimeoutPrecision,
      AshWorkflow.Verifiers.ValidateTransitionLog,
      AshWorkflow.Verifiers.ValidateUndo,
      AshWorkflow.Verifiers.ValidateStepPolicies
    ]
end
