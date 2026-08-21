[
  tools: [
    {:compiler, "mix compile --warnings-as-errors --force"},
    {:unused_deps, "mix deps.unlock --check-unused"},
    {:formatter, "mix format --check-formatted"},
    {:credo, "mix credo --strict"},
    {:hex_audit, "mix hex.audit"},
    {:deps_audit, "mix deps.audit"},
    {:ex_unit, "mix test --cover"},
    {:dialyzer, "mix dialyzer"},
    {:ex_doc, "mix docs", env: %{"MIX_ENV" => "dev"}},

    # The usage rules synced from dependencies must not drift from the
    # installed versions. Drift in our *own* rules is covered by
    # test/documentation_drift_test.exs.
    {:usage_rules, "bin/check-usage-rules.sh", env: %{"MIX_ENV" => "dev"}},

    # Not a Phoenix app; no endpoints or templates for sobelow to analyse.
    {:sobelow, false}
  ]
]
