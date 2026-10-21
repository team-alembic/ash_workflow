defmodule AshWorkflow.Charts.TextWidth do
  @moduledoc false
  # Spike: estimates text width from the Helvetica advance widths, because
  # Elixir has no font metrics. The SVG names Helvetica, then Arial, which has
  # the same widths. Characters outside ASCII get a guess: symbols and emoji
  # one em, a variation selector nothing, anything else the width of "n".

  @ascii %{
    ?\s => 278,
    ?! => 278,
    ?" => 355,
    ?# => 556,
    ?$ => 556,
    ?% => 889,
    ?& => 667,
    ?' => 191,
    ?( => 333,
    ?) => 333,
    ?* => 389,
    ?+ => 584,
    ?, => 278,
    ?- => 333,
    ?. => 278,
    ?/ => 278,
    ?0 => 556,
    ?1 => 556,
    ?2 => 556,
    ?3 => 556,
    ?4 => 556,
    ?5 => 556,
    ?6 => 556,
    ?7 => 556,
    ?8 => 556,
    ?9 => 556,
    ?: => 278,
    ?; => 278,
    ?< => 584,
    ?= => 584,
    ?> => 584,
    ?? => 556,
    ?@ => 1015,
    ?A => 667,
    ?B => 667,
    ?C => 722,
    ?D => 722,
    ?E => 667,
    ?F => 611,
    ?G => 778,
    ?H => 722,
    ?I => 278,
    ?J => 500,
    ?K => 667,
    ?L => 556,
    ?M => 833,
    ?N => 722,
    ?O => 778,
    ?P => 667,
    ?Q => 778,
    ?R => 722,
    ?S => 667,
    ?T => 611,
    ?U => 722,
    ?V => 667,
    ?W => 944,
    ?X => 667,
    ?Y => 667,
    ?Z => 611,
    ?[ => 278,
    ?\\ => 278,
    ?] => 278,
    ?^ => 469,
    ?_ => 556,
    ?` => 333,
    ?a => 556,
    ?b => 556,
    ?c => 500,
    ?d => 556,
    ?e => 556,
    ?f => 278,
    ?g => 556,
    ?h => 556,
    ?i => 222,
    ?j => 222,
    ?k => 500,
    ?l => 222,
    ?m => 833,
    ?n => 556,
    ?o => 556,
    ?p => 556,
    ?q => 556,
    ?r => 333,
    ?s => 500,
    ?t => 278,
    ?u => 556,
    ?v => 500,
    ?w => 722,
    ?x => 500,
    ?y => 500,
    ?z => 500,
    ?{ => 334,
    ?| => 260,
    ?} => 334,
    ?~ => 584
  }

  def font_family, do: "Helvetica, Arial, sans-serif"

  def width(text, font_size) do
    thousandths = text |> String.to_charlist() |> Enum.map(&advance/1) |> Enum.sum()
    Float.round(thousandths * font_size / 1000, 2)
  end

  defp advance(char) when is_map_key(@ascii, char), do: @ascii[char]
  defp advance(char) when char in 0xFE00..0xFE0F, do: 0
  defp advance(char) when char >= 0x2000, do: 1000
  defp advance(_char), do: 556

  def wrap(text, max_width, font_size) do
    text
    |> String.split(" ", trim: true)
    |> Enum.reduce([], fn
      word, [] ->
        [word]

      word, [line | done] ->
        candidate = line <> " " <> word

        if width(candidate, font_size) <= max_width,
          do: [candidate | done],
          else: [word, line | done]
    end)
    |> Enum.reverse()
  end
end
