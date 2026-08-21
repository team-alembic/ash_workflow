defmodule DocumentApproval.Document.Validate do
  @moduledoc """
  Stands in for whatever automatic checking a real system does before a document
  reaches a human — formatting, virus scanning, link checking.

  A document whose body is too short to be worth reviewing fails, which is how
  the demo exercises the `on_error` path.
  """

  @minimum_body_length 10
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    body = Ash.Changeset.get_attribute(changeset, :body)

    if String.length(String.trim(body)) < @minimum_body_length do
      Ash.Changeset.add_error(changeset,
        field: :body,
        message: "document body is too short to review"
      )
    else
      changeset
    end
  end
end
