defmodule AshWorkflow.Entities.BelongsToActor do
  @moduledoc """
  Configures actor capture on a `transition_log`.

  When present, `AshWorkflow.Changes.RecordEvent` sets this attribute on every
  log row it writes to `context.actor`, following AshPaperTrail's
  `belongs_to_actor` precedent rather than the library guessing an actor type.
  """

  defstruct [:name, :destination, __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: atom(),
          destination: module()
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
    ]
  ]

  def attribute_schema, do: @schema
end
