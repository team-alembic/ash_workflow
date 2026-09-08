defmodule AshWorkflowTest.OnSuccessThreeWayWorkflow do
  @moduledoc """
  Three conditional `on_success` entries covering disjoint ranges, so the
  middle one has a chance to actually win — existing fixtures only ever have
  two live conditions (a third, where present, is a shadowed duplicate used to
  test ordering).

  start → classifying ──(score < 3)───────────▶ low
                       └─(3 <= score < 7)─────▶ mid
                       └─(score >= 7)──────────▶ high
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step :classifying do
      action :run_classification

      on_success :low, when: expr(score < 3)
      on_success :mid, when: expr(score >= 3 and score < 7)
      on_success :high, when: expr(score >= 7)
    end

    step :low, terminal: true
    step :mid, terminal: true
    step :high, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept [:score]
    end

    update :run_classification do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :score, :integer, public?: true
  end
end
