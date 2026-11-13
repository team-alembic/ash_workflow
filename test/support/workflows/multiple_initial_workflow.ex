defmodule AshWorkflowTest.MultipleInitialWorkflow do
  @moduledoc """
  Workflow with two initial steps, neither reachable from the other.

  start → start_one ──(finish)──→ done
  start → start_two ──(finish)──→ done

  `:create` starts in `:start_one`, the first initial step by declaration
  order. `:create_at_start_two` names the other one.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :start_one do
      initial true
      transition :finish, to: :done
    end

    step :start_two do
      initial true
      transition :finish, to: :done
    end

    step :done, terminal: true
  end

  code_interface do
    define :create
    define :create_at_start_two
    define :create_at_done
  end

  actions do
    create :create do
      accept [:title]
    end

    create :create_at_start_two do
      accept [:title]
      change transition_state(:start_two)
    end

    create :create_at_done do
      accept [:title]
      change transition_state(:done)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false
  end
end
