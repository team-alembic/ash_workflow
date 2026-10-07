defmodule AshWorkflow.DeckDslTest do
  @moduledoc """
  Compiles the AshWorkflow DSL shown in
  `slides/2026-ashconf-when-time-meets-state/deck.md`.

  A conference slide is the one place library DSL gets read by hundreds of
  people and checked by nobody. These tests put every DSL block through
  `Code.compile_string` inside the resource its fixture supplies, so an option
  that does not exist, or a step that aims at a state nothing declares, fails
  the build rather than the talk.

  `AshWorkflowTest.DeckBlocks` documents the tagging and holds the fixtures.
  """
  use ExUnit.Case, async: true

  alias AshWorkflowTest.DeckBlocks

  @moduletag :deck

  if DeckBlocks.deck?() do
    describe "every Elixir block in the deck is tagged" do
      for %{line: line, tag: tag} <- DeckBlocks.blocks() do
        test "#{DeckBlocks.deck()}:#{line} carries a tag the test understands" do
          tag = unquote(tag)
          valid = ["illustrative" | Enum.map(DeckBlocks.fixture_names(), &"ash_workflow:#{&1}")]

          assert tag in valid, """
          The Elixir block at #{DeckBlocks.deck()}:#{unquote(line)} is tagged \
          `#{tag}`, which is not a tag this test knows.

          Tag the fence `elixir ash_workflow:<fixture>` to have the block \
          compiled, naming one of: #{Enum.join(DeckBlocks.fixture_names(), ", ")}. \
          Tag it `elixir illustrative` if it is not AshWorkflow DSL. Neither tag \
          renders in the slide.
          """
        end
      end
    end

    describe "every DSL block in the deck compiles" do
      for %{tag: "ash_workflow:" <> _, line: line} = block <- DeckBlocks.blocks() do
        test "#{DeckBlocks.deck()}:#{line} compiles as #{block.tag}" do
          block = unquote(Macro.escape(block))

          errors = DeckBlocks.compile(block)

          assert errors == [], """
          The DSL at #{DeckBlocks.deck()}:#{block.line} does not survive its own \
          verifiers:

          #{Enum.map_join(errors, "\n\n", fn {module, error} -> "#{inspect(module)}: #{Exception.message(error)}" end)}
          """
        end
      end
    end
  end
end
