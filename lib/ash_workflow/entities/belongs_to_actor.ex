defmodule AshWorkflow.Entities.BelongsToActor do
  @moduledoc """
  Configures actor capture on a `transition_log`.

  When present, `AshWorkflow.Changes.RecordEvent` sets this attribute on every
  log row it writes to `context.actor`, following AshPaperTrail's
  `belongs_to_actor` precedent rather than the library guessing an actor type.
  With `skip_other_actors?: true`, an actor that is not a `destination` struct,
  such as a plain-struct system actor, leaves the attribute `nil`.
  """

  defstruct [:name, :destination, skip_other_actors?: false, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: atom(),
          destination: module(),
          skip_other_actors?: boolean()
        }

  @schema [
    name: [
      type: :atom,
      required: true,
      doc: "The attribute on the transition log resource that stores the actor, e.g. :user."
    ],
    destination: [
      type: :atom,
      required: true,
      doc: "The actor resource module, e.g. MyApp.Accounts.User."
    ],
    skip_other_actors?: [
      type: :boolean,
      default: false,
      doc: """
      Whether an actor that is not a `destination` struct is recorded as `nil`.
      Set it when actions also run as another actor, such as a plain-struct
      system actor, which has no primary key to record. When `false`, such an
      actor raises when its log row is written, and an actor of another
      resource has its primary key written to the foreign key. With
      `same_actor?` undo, a skipped actor is refused with `:no_actor`.
      """
    ]
  ]

  def attribute_schema, do: @schema
end
