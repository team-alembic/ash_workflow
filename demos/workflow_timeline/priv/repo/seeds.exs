# Populates the database with responders and a batch of incidents whose
# transition-log history has already been backdated across the last ten
# days, so the timeline is immediately meaningful without waiting for real
# timeouts to fire. Run with:
#
#     mix run priv/repo/seeds.exs

alias WorkflowTimeline.IncidentResponse.Responder
alias WorkflowTimeline.Seeder

Application.put_env(:workflow_timeline, :fast_tests, true)

responders = [
  {"Priya Nandakumar", "SRE"},
  {"Jonas Weber", "Platform"},
  {"Mei Tanaka", "SRE"},
  {"Diego Alvarez", "Platform"}
]

Enum.each(responders, fn {name, team} ->
  Responder
  |> Ash.Changeset.for_create(:create, %{name: name, team: team})
  |> Ash.create!()
end)

Seeder.seed_many!(10)

# The undo page's own incidents. Not backdated: undo is configured `within {1,
# :hours}`, so a ten-day-old incident would arrive with its window already shut.
for _ <- 1..3, do: Seeder.seed_undoable_incident!()

Application.delete_env(:workflow_timeline, :fast_tests)

IO.puts(
  "Seeded #{length(responders)} responders, 10 incidents with backdated history, " <>
    "and 3 undoable incidents."
)
