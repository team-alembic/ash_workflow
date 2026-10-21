defmodule AshWorkflow.Charts.TextWidthTest do
  use ExUnit.Case, async: true

  alias AshWorkflow.Charts.TextWidth

  test "width/2 sums the Helvetica advance widths" do
    # "Hi": H 722 + i 222 = 944 thousandths of an em.
    assert TextWidth.width("Hi", 10) == 9.44
  end

  test "the emoji gear is one em: the text gear plus U+FE0F" do
    assert TextWidth.width("⚙\u{FE0F}", 14) == 14.0
  end

  test "wrap/3 breaks at spaces and keeps each line under the width" do
    lines = TextWidth.wrap("go when amount > 100 and region == :eu", 120, 14)

    assert length(lines) > 1
    assert Enum.all?(lines, &(TextWidth.width(&1, 14) <= 120))
    assert Enum.join(lines, " ") == "go when amount > 100 and region == :eu"
  end

  test "wrap/3 keeps a single word that is too long on its own line" do
    assert TextWidth.wrap("supercalifragilistic", 20, 14) == ["supercalifragilistic"]
  end
end
