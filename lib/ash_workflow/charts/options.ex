defmodule AshWorkflow.Charts.Options do
  @moduledoc false
  # The `:theme`, `:direction` and `:classes` options of the backends that
  # draw in colour, such as `AshWorkflow.Charts.Dot`. A backend gives its
  # defaults and a `t:spec/0` with the words of its messages, so the checks
  # and the merge are the same in each backend. An option or a config key
  # set to `nil` counts as not set, so a runtime config can read a value from
  # a variable that may not be set.

  @themes [:light, :dark]

  @typedoc """
  What differs between backends:

  * `:backend` — the name in a message, such as `"DOT"`.
  * `:config` — the key under `config :ash_workflow`, such as `:dot`.
  * `:known_keys` — the keys a class may set, as strings. The command
    rejects any other key, so a class key must be one of these.
  * `:key` — what a key is, in a message, such as `"DOT attribute name"`.
  * `:keys` — what the keys of a class are, such as `"DOT attributes"`.
  * `:entry` — what an entry is, such as `"an attribute name"`.
  * `:example` — a list of classes, as text, for a message.
  """
  @type spec :: %{
          backend: String.t(),
          config: atom(),
          known_keys: [String.t()],
          key: String.t(),
          keys: String.t(),
          entry: String.t(),
          example: String.t()
        }

  @doc """
  The theme: the option, else `:theme` in the config, else `:light`.
  """
  @spec theme!(atom() | nil, keyword()) :: :light | :dark
  def theme!(option, config) do
    case option || Keyword.get(config, :theme) || :light do
      theme when theme in @themes -> theme
      other -> raise ArgumentError, "theme must be :light or :dark, got: #{inspect(other)}"
    end
  end

  @doc """
  The direction, when it is `:down` or `:right`. `nil` is `:down`.
  """
  @spec direction!(atom() | nil) :: :down | :right
  def direction!(nil), do: :down
  def direction!(direction) when direction in [:down, :right], do: direction

  def direction!(other),
    do: raise(ArgumentError, "direction must be :down or :right, got: #{inspect(other)}")

  @doc """
  The classes for a theme. The configured classes merge over `defaults`, and
  the option merges over both. A class keeps the default keys it does not
  set, so `stroke: "#000"` on `manual` keeps the amber fill.
  """
  @spec classes!(keyword(keyword()), :light | :dark, term(), keyword(), spec()) ::
          keyword(keyword())
  def classes!(defaults, theme, option, config, spec) do
    configured =
      (Keyword.get(config, :classes) || [])
      |> theme_classes!(
        theme,
        defaults,
        spec,
        "config :ash_workflow, #{inspect(spec.config)}, classes:"
      )

    option = theme_classes!(option || [], theme, defaults, spec, "the :classes option")

    Enum.reduce(configured ++ option, defaults, &merge_class/2)
  end

  # `[light: [...], dark: [...]]` gives classes for each theme, and only the
  # entries for the current theme apply. A list of classes applies to every
  # theme. Every entry is validated, so an error in the dark entry shows in
  # a light chart too. A theme given twice applies both entries in order.
  defp theme_classes!(classes, theme, defaults, spec, source) do
    themed? = &match?({key, _style} when key in @themes, &1)

    cond do
      not is_list(classes) or not Enum.any?(classes, themed?) ->
        validate_classes!(classes, defaults, spec, source)

      Enum.all?(classes, themed?) ->
        classes
        |> Enum.map(fn {key, entry} ->
          {key, validate_classes!(entry, defaults, spec, "#{source} (#{inspect(key)})")}
        end)
        |> Keyword.get_values(theme)
        |> Enum.concat()

      true ->
        raise ArgumentError,
              "#{source} must be a list of classes, or a list with :light and :dark keys " <>
                "such as [light: #{spec.example}], not a mix of both, " <>
                "got: #{inspect(classes)}"
    end
  end

  # The shape is a keyword list of keyword lists, and a key is written into
  # the file as it is. So a key must be one of the backend's known keys, and
  # a value must be a string, which is quoted, or a number or a boolean,
  # which is not. Anything else would break the file.
  defp validate_classes!(classes, defaults, spec, source) do
    if not (is_list(classes) and
              Enum.all?(
                classes,
                &match?({class, style} when is_atom(class) and is_list(style), &1)
              )) do
      raise ArgumentError,
            "#{source} must be a keyword list from a class name to a keyword list of #{spec.keys}, " <>
              "such as #{spec.example}, got: #{inspect(classes)}"
    end

    Enum.map(classes, fn {class, style} ->
      if not Keyword.has_key?(defaults, class) do
        raise ArgumentError,
              "#{source}: unknown #{spec.backend} class #{inspect(class)}. " <>
                "The classes are #{inspect(Keyword.keys(defaults))}"
      end

      {class, Enum.map(style, &entry!(&1, class, spec, source))}
    end)
  end

  defp entry!({key, value}, class, spec, source) when is_atom(key) or is_binary(key) do
    key = to_string(key)

    cond do
      key not in spec.known_keys ->
        raise ArgumentError,
              "#{source}: #{inspect(key)} under #{inspect(class)} is not a #{spec.key}. " <>
                "The keys are #{Enum.join(spec.known_keys, ", ")}"

      not (is_binary(value) or is_number(value) or is_boolean(value)) ->
        raise ArgumentError,
              "#{source}: #{key} under #{inspect(class)} must be a string, a number or a boolean, " <>
                "got: #{inspect(value)}"

      true ->
        {String.to_atom(key), value}
    end
  end

  defp entry!(other, class, spec, source) do
    raise ArgumentError,
          "#{source}: #{inspect(other)} under #{inspect(class)} is not #{spec.entry} and value"
  end

  defp merge_class({class, style}, classes),
    do: Keyword.update!(classes, class, &merge_style(&1, style))

  # Keeps the default key order, so an override changes a value in place and
  # a new key goes last. `Keyword.merge/2` would move a changed key to the end.
  # For a key given twice, the last value wins, as in `Keyword.merge/2`.
  defp merge_style(default, overrides) do
    overrides = Keyword.new(overrides)

    kept = Enum.map(default, fn {key, value} -> {key, Keyword.get(overrides, key, value)} end)
    kept ++ Enum.reject(overrides, fn {key, _value} -> Keyword.has_key?(default, key) end)
  end

  @doc """
  A float in fixed notation, such as `0.0001`, because a file that has an
  exponent, such as `1.0e-4`, does not parse in every backend.
  """
  @spec decimal(float()) :: String.t()
  def decimal(value), do: :erlang.float_to_binary(value, [:compact, decimals: 10])
end
