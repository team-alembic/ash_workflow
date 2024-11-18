defmodule AshWorkflow.Dsl.Switch do
  defstruct default: nil,
            matches: [],
            name: nil,
            on: nil

  alias AshWorkflow.{
    Dsl.Switch,
    Dsl.Switch.Default,
    Dsl.Switch.Match,
    Dsl.ActionStep,
    Dsl.WorkflowStep,
    Template
  }

  @type t :: %Switch{
          default: nil | Default.t(),
          matches: [Match.t()],
          name: atom,
          on: Template.Input.t() | Template.Result.t() | Template.Value.t()
        }

  @switch_match %Spark.Dsl.Entity{
    name: :matches?,
    describe: """
    A group of steps to run when the predicate matches.
    """,
    target: Match,
    args: [:predicate],
    entities: [
      step: [
        WorkflowStep.__entity__(),
        ActionStep.__entity__()
      ]
    ],
    singleton_entity_keys: [:step],
    schema: [
      predicate: [
        type: {:mfa_or_fun, 1},
        required: true,
        doc: """
        A one-arity function which is used to match the switch input. If the switch returns a truthy value, then the nested steps will be run.
        """
      ]
    ]
  }

  @switch_default %Spark.Dsl.Entity{
    name: :default,
    describe: """
    If none of the `matches?` branches match the input, then the `default`
    steps will be run if provided.
    """,
    target: Default,
    entities: [
      step: [
        WorkflowStep.__entity__(),
        ActionStep.__entity__()
      ]
    ],
    singleton_entity_keys: [:step],
    schema: []
  }

  def __entity__,
    do: %Spark.Dsl.Entity{
      name: :switch,
      describe: """
      Use a predicate to determine which steps should be executed.
      """,
      target: Switch,
      args: [:name],
      imports: [Template],
      entities: [matches: [@switch_match], default: [@switch_default]],
      singleton_entity_keys: [:default],
      recursive_as: :step,
      schema: [
        name: [
          type: :atom,
          required: true,
          doc: """
          A unique name for the switch.
          """
        ],
        on: [
          type: Template.type(),
          required: true,
          doc: """
          The value to match against.
          """
        ]
      ]
    }
end
