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

Application.delete_env(:workflow_timeline, :fast_tests)

IO.puts("Seeded #{length(responders)} responders and 10 incidents with backdated history.")
