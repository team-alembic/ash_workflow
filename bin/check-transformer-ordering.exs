# Asserts AshWorkflow's transformer ordering contracts without booting the test
# suite. Run as:
#
#     MIX_ENV=test mix run bin/check-transformer-ordering.exs
#
# `test/ash_workflow/transformer_ordering_test.exs` checks the same thing, but a
# broken ordering can stop `test/test_helper.exs` from starting — AshOban raises
# on an unconfigured queue before ExUnit does anything — so the suite cannot
# always report this failure. This script always can.

alias AshWorkflowTest.TransformerContracts

resources = Ash.Domain.Info.resources(AshWorkflowTest.Domain)

violations =
  Enum.flat_map(resources, fn resource ->
    Enum.map(TransformerContracts.violations(resource), &{resource, &1})
  end)

case violations do
  [] ->
    IO.puts("transformer ordering OK across #{length(resources)} resources")

  violations ->
    IO.puts("#{length(violations)} transformer ordering violation(s):\n")

    Enum.each(violations, fn {resource, violation} ->
      IO.puts("  #{inspect(resource)}")
      TransformerContracts.explain(violation) |> String.split("\n") |> Enum.each(&IO.puts("    #{&1}"))
    end)

    System.halt(1)
end
