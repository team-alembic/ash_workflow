require Ash.Query

defmodule P6.AllVersions do
  @moduledoc "A manual read action: builds the data layer query itself and leaves as_of unset."
  use Ash.Resource.ManualRead

  def read(ash_query, _ecto_query, _opts, _context) do
    query = Ash.DataLayer.Ets.resource_to_query(ash_query.resource, ash_query.domain)
    # Deliberately never calling Ash.DataLayer.set_as_of/3.
    Ash.DataLayer.Ets.run_query(query, ash_query.resource)
  end
end

defmodule P6.Domain do
  use Ash.Domain, validate_config_inclusion?: false
  resources(do: resource(P6.Candidate))
end

defmodule P6.Candidate do
  use Ash.Resource,
    domain: P6.Domain,
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

    read :all_versions do
      manual P6.AllVersions
    end

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
at = fn i -> P6.Candidate |> Ash.Query.filter(id == 1) |> Ash.Query.as_of(i) |> Ash.read_one!() end

P6.Candidate
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

IO.puts("\n=== ordinary read (as_of defaults) ===")
IO.puts("  #{length(Ash.read!(P6.Candidate))} row(s)")

IO.puts("\n=== manual read action, as_of never set ===")

case Ash.read(P6.Candidate, action: :all_versions) do
  {:ok, rows} ->
    IO.puts("  #{length(rows)} row(s) — ONE query\n")

    rows
    |> Enum.sort_by(& &1.valid_at.lower, DateTime)
    |> Enum.each(fn r ->
      upper = if r.valid_at.upper, do: inspect(r.valid_at.upper), else: "open"

      IO.puts(
        "    #{inspect(r.valid_at.lower)} -> #{String.pad_trailing(upper, 26)} state=#{inspect(r.state)}  by=#{inspect(r.triggered_by)}"
      )
    end)

  {:error, e} ->
    IO.puts("  failed: #{Exception.message(e) |> String.slice(0, 300)}")
end
