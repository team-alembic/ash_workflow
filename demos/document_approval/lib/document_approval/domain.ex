defmodule DocumentApproval.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource DocumentApproval.Document
  end
end
