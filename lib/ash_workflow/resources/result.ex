defmodule AshWorkflow.Resources.Result do
  alias AshWorkflow.Resources.Result.{Reference, Embed}

  @reference :reference
  @embed :embed

  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      storage: :map_with_tag,
      types: [
        {@embed,
         [
           type: Embed,
           tag: :type,
           tag_value: @embed
         ]},
        {@reference,
         [
           type: Reference,
           tag: :type,
           tag_value: @reference
         ]}
      ]
    ]
end
