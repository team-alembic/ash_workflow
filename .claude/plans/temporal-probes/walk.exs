require Ash.Query

defmodule P5.Domain do
  use Ash.Domain, validate_config_inclusion?: false
  resources(do: resource(P5.Candidate))
end

defmodule P5.Candidate do
  use Ash.Resource,
    domain: P5.Domain,
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

    transitions do
      transition :interview, from: :review, to: :interview
      transition :reject, from: [:review, :interview], to: :rejected
    end
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :notes, :string, public?: true
    attribute :triggered_by, :string, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:id, :triggered_by]
    end

    update :add_note do
      accept [:notes, :triggered_by]
    end

    update :interview do
      accept [:triggered_by]
      change transition_state(:interview)
    end

    update :reject do
      accept [:triggered_by]
      change transition_state(:rejected)
    end
  end
end

t = fn h -> DateTime.new!(~D[2026-01-01], Time.new!(h, 0, 0)) end
at = fn i -> P5.Candidate |> Ash.Query.filter(id == 1) |> Ash.Query.as_of(i) |> Ash.read_one!() end

P5.Candidate
|> Ash.Changeset.for_create(:create, %{id: 1, triggered_by: "applicant"})
|> Ash.Changeset.as_of(t.(9))
|> Ash.create!()

at.(t.(9))
|> Ash.Changeset.for_update(:add_note, %{notes: "strong portfolio", triggered_by: "recruiter:kim"})
|> Ash.Changeset.as_of(t.(10))
|> Ash.update!()

at.(t.(10))
|> Ash.Changeset.for_update(:interview, %{triggered_by: "recruiter:kim"})
|> Ash.Changeset.as_of(t.(11))
|> Ash.update!()

at.(t.(11))
|> Ash.Changeset.for_update(:reject, %{triggered_by: "timeout:escalation"})
|> Ash.Changeset.as_of(t.(12))
|> Ash.update!()

# Walk forward from the first known instant, following each version's upper bound.
walk = fn start ->
  Stream.unfold({start, 0}, fn
    {nil, _} ->
      nil

    {instant, n} when n < 50 ->
      case at.(instant) do
        nil -> nil
        record -> {record, {record.valid_at.upper, n + 1}}
      end

    _ ->
      nil
  end)
  |> Enum.to_list()
end

versions = walk.(t.(9))

IO.puts("\n=== walking the chain via each version's upper bound ===")
IO.puts("recovered #{length(versions)} versions in #{length(versions) + 1} queries\n")

Enum.each(versions, fn r ->
  upper = if r.valid_at.upper, do: inspect(r.valid_at.upper), else: "open"

  IO.puts(
    "  #{inspect(r.valid_at.lower)} -> #{String.pad_trailing(upper, 26)} state=#{inspect(r.state)}  by=#{inspect(r.triggered_by)}"
  )
end)

transitions =
  versions
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.filter(fn [a, b] -> a.state != b.state end)

IO.puts("\n=== state transitions only (versions where state actually changed) ===")

Enum.each(transitions, fn [a, b] ->
  IO.puts("  #{inspect(b.valid_at.lower)}  #{inspect(a.state)} -> #{inspect(b.state)}  by=#{inspect(b.triggered_by)}")
end)

IO.puts("\n  #{length(versions)} versions, but only #{length(transitions)} were state changes.")
