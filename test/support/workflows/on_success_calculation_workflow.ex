defmodule AshWorkflowTest.OnSuccessCalculationWorkflow do
  @moduledoc """
  An `on_success` condition over an `expr`-backed calculation rather than a
  plain attribute, proving the route's `when` can reference calculated state
  the same way a manual `transition`'s `route` can.

  start → screening ──(is_strong)──────────▶ interview
                     └─(not is_strong)─────▶ rejected
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :screening do
      action :run_screening

      on_success :interview, when: expr(is_strong)
      on_success :rejected, when: expr(not is_strong)
      on_error :screening_failed
    end

    step :interview, terminal: true
    step :rejected, terminal: true
    step :screening_failed, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:title]
    end

    update :run_screening do
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        if Ash.Changeset.get_attribute(changeset, :title) == "strong" do
          Ash.Changeset.change_attribute(changeset, :screen_score, 8)
        else
          Ash.Changeset.change_attribute(changeset, :screen_score, 2)
        end
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :screen_score, :integer, public?: true
  end

  calculations do
    calculate :is_strong, :boolean, expr(screen_score >= 5)
  end
end
