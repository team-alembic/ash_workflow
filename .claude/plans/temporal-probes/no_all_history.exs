require Ash.Query

defmodule P3.Domain do
  use Ash.Domain, validate_config_inclusion?: false
  resources(do: resource(P3.Candidate))
end

defmodule P3.Candidate do
  use Ash.Resource,
    domain: P3.Domain,
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
    # the user's suggestion: carry causality on the row itself
    attribute :triggered_by, :string, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:id, :notes, :triggered_by]
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

P3.Candidate
|> Ash.Changeset.for_create(:create, %{id: 1, triggered_by: "applicant"})
|> Ash.Changeset.as_of(t.(9))
|> Ash.create!()

read_at = fn instant ->
  P3.Candidate |> Ash.Query.filter(id == 1) |> Ash.Query.as_of(instant) |> Ash.read_one!()
end

read_at.(t.(9))
|> Ash.Changeset.for_update(:interview, %{triggered_by: "recruiter:kim"})
|> Ash.Changeset.as_of(t.(10))
|> Ash.update!()

read_at.(t.(10))
|> Ash.Changeset.for_update(:reject, %{triggered_by: "timeout:escalation"})
|> Ash.Changeset.as_of(t.(11))
|> Ash.update!()

IO.puts("\n=== 1. plain read, NO as_of passed ===")
rows = P3.Candidate |> Ash.Query.filter(id == 1) |> Ash.read!()
IO.puts("returned #{length(rows)} row(s)")

for r <- Enum.sort_by(rows, & &1.valid_at.lower, DateTime) do
  IO.puts(
    "  #{inspect(r.valid_at.lower)} -> #{inspect(r.valid_at.upper)}  state=#{inspect(r.state)}  triggered_by=#{inspect(r.triggered_by)}"
  )
end

IO.puts("\n=== 2. read with as_of: :now ===")
now_rows = P3.Candidate |> Ash.Query.filter(id == 1) |> Ash.Query.as_of(:now) |> Ash.read!()
IO.puts("returned #{length(now_rows)} row(s)")

IO.puts("\n=== 3. can we filter/sort on the period attribute directly? ===")

try do
  sorted =
    P3.Candidate
    |> Ash.Query.filter(id == 1)
    |> Ash.Query.sort(valid_at: :asc)
    |> Ash.read!()

  IO.puts("sort on valid_at worked, #{length(sorted)} row(s)")
rescue
  e -> IO.puts("sort on valid_at failed: #{Exception.message(e) |> String.slice(0, 160)}")
end

IO.puts("\n=== VERDICT ===")

if length(rows) > 1 do
  IO.puts("  Omitting as_of returned ALL #{length(rows)} versions in ONE query.")
  IO.puts("  With triggered_by on the row, that is an ordered, causal timeline.")
else
  IO.puts("  Omitting as_of returned only the current version. No all-history read.")
end
