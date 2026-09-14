require Ash.Query

defmodule Probe2.Domain do
  use Ash.Domain, validate_config_inclusion?: false
  resources(do: resource(Probe2.Candidate))
end

defmodule Probe2.Candidate do
  use Ash.Resource,
    domain: Probe2.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStateMachine]

  ets(do: private?(true))

  temporal do
    strategy :context
    attribute :valid_at
  end

  state_machine do
    initial_states [:review]
    default_initial_state :review
    transitions(do: transition(:reject, from: :review, to: :rejected))
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :notes, :string, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:id, :notes]
    end

    update :add_note do
      accept [:notes]
    end

    update :reject do
      change transition_state(:rejected)
    end
  end
end

t0 = ~U[2026-01-01 09:00:00Z]
t1 = ~U[2026-01-01 10:00:00Z]
t2 = ~U[2026-01-01 11:00:00Z]

Probe2.Candidate
|> Ash.Changeset.for_create(:create, %{id: 1, notes: nil})
|> Ash.Changeset.set_context(%{private: %{as_of: t0}})
|> Ash.Changeset.as_of(t0)
|> Ash.create!()

read_at = fn t ->
  require Ash.Query
  Probe2.Candidate
  |> Ash.Query.filter(id == 1)
  |> Ash.Query.as_of(t)
  |> Ash.read_one!()
end

after_create = read_at.(t0)
IO.puts("\nafter create, read as_of t0:")
IO.puts("  state=#{inspect(after_create.state)} valid_at=#{inspect(after_create.valid_at)}")

after_create
|> Ash.Changeset.for_update(:add_note, %{notes: "strong portfolio"})
|> Ash.Changeset.as_of(t1)
|> Ash.update!()

IO.puts("\nafter add_note at t1 (NO state change):")

for {label, t} <- [{"as_of t0", t0}, {"as_of t1", t1}] do
  r = read_at.(t)
  IO.puts("  #{label}: state=#{inspect(r.state)} valid_at=#{inspect(r.valid_at)}")
end

read_at.(t1)
|> Ash.Changeset.for_update(:reject, %{})
|> Ash.Changeset.as_of(t2)
|> Ash.update!()

IO.puts("\nafter reject at t2 (state change):")

for {label, t} <- [{"as_of t0", t0}, {"as_of t1", t1}, {"as_of t2", t2}] do
  r = read_at.(t)
  IO.puts("  #{label}: state=#{inspect(r.state)} valid_at=#{inspect(r.valid_at)}")
end

current = read_at.(t1)

IO.puts("\nVERDICT")

if current.valid_at.lower == t0 do
  IO.puts("  lower(valid_at) stayed at t0 across a non-state update.")
  IO.puts("  It tracks state entry. Safe as a timeout anchor.")
else
  IO.puts("  lower(valid_at) moved from #{inspect(t0)} to #{inspect(current.valid_at.lower)}")
  IO.puts("  on an update that did NOT change state.")
  IO.puts("  It tracks the last write, not state entry.")
end
