defmodule AshWorkflowTest.RaisingStepWorkflow do
  @moduledoc """
  An automatic step whose change raises instead of adding an error.

  `AshWorkflowTest.Changes.MaybeFailChange` fails by adding an error to the
  changeset, so the action returns `{:error, _}`. This one raises from
  `change/3`, which happens while `Ash.Changeset.for_update/4` is still
  building the changeset and never reaches `Ash.update/2`.

  Both are a failed step, and `AshWorkflow.Scheduler.execute/3` routes both to
  `on_error`. A raise used to escape it.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  defmodule Change do
    @moduledoc false
    use Ash.Resource.Change

    defmodule RaisedError do
      @moduledoc false
      defexception message: "the change raised"
    end

    @impl true
    def change(_changeset, _opts, _context), do: raise(RaisedError)
  end

  workflow do
    step :process, action: :do_processing, on_success: :done, on_error: :failed
    step :done, terminal: true
    step :failed, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title]
    end

    update :do_processing do
      accept []
      require_atomic? false
      change AshWorkflowTest.RaisingStepWorkflow.Change
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end
end
