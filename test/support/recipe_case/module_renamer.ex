defmodule AshWorkflow.RecipeCase.ModuleRenamer do
  @moduledoc """
  Moves the modules defined in Elixir source under a namespace, and rewrites the
  references to them.

  References are resolved the way the compiler resolves them, through `alias`,
  grouped `alias X.{A, B}`, and the alias a nested `defmodule` adds. Aliases are
  tracked per module, not per function body.
  """

  @skip :recipe_renamer_skip

  @doc "Returns the full names of the modules `content` defines, nested ones included."
  @spec defined_modules(String.t()) :: [module()]
  def defined_modules(content) do
    content
    |> Sourceror.parse_string!()
    |> walk([], fn
      {:defmodule, node, module, _via}, acc -> {node, [module | acc]}
      {_kind, node, _module, _via}, acc -> {node, acc}
    end)
    |> elem(1)
  end

  @doc "Moves every module in `modules` that `content` defines or references under `namespace`."
  @spec rename(String.t(), String.t(), MapSet.t(module())) :: String.t()
  def rename(content, namespace, modules) do
    ast = content |> Sourceror.parse_string!() |> split_grouped_aliases()
    moved_aliases = moved_aliases(ast, modules)

    ast
    |> walk(nil, fn event, acc -> {rewrite(event, namespace, modules, moved_aliases), acc} end)
    |> elem(0)
    |> Sourceror.to_string()
  end

  @doc "Returns the modules in `modules` that `content` still references."
  @spec references(String.t(), MapSet.t(module())) :: [module()]
  def references(content, modules) do
    ast = Sourceror.parse_string!(content)

    {_ast, referenced} =
      walk(ast, MapSet.new(), fn {_kind, node, module, _via}, acc ->
        {node, add_if_member(acc, module, modules)}
      end)

    {_ast, referenced} =
      Macro.prewalk(ast, referenced, fn
        atom, acc when is_atom(atom) -> {atom, add_if_member(acc, atom, modules)}
        node, acc -> {node, acc}
      end)

    referenced |> MapSet.to_list() |> Enum.sort()
  end

  defp add_if_member(acc, module, modules) do
    if MapSet.member?(modules, module), do: MapSet.put(acc, module), else: acc
  end

  # An alias is moved when its target is moved, or when every reference made
  # through it is. Otherwise it stays, and the moved references through it are
  # written out in full.
  defp moved_aliases(ast, modules) do
    {_ast, {targets, references}} =
      walk(ast, {%{}, %{}}, fn
        {:alias, node, module, {:alias, id}}, {targets, references} ->
          {node, {Map.put(targets, id, module), references}}

        {:reference, node, module, {:via, id}}, {targets, references} ->
          {node, {targets, Map.update(references, id, [module], &[module | &1])}}

        {_kind, node, _module, _via}, acc ->
          {node, acc}
      end)

    for {id, target} <- targets,
        MapSet.member?(modules, target) or
          Enum.all?(Map.get(references, id, [nil]), &MapSet.member?(modules, &1)),
        into: MapSet.new(),
        do: id
  end

  defp rewrite({:alias, node, module, {:alias, id}}, namespace, _modules, moved_aliases) do
    if MapSet.member?(moved_aliases, id), do: moved(node, namespace, module), else: node
  end

  defp rewrite({:reference, node, module, via}, namespace, modules, moved_aliases) do
    cond do
      not MapSet.member?(modules, module) -> node
      match?({:via, _}, via) and MapSet.member?(moved_aliases, elem(via, 1)) -> node
      via in [:implicit, :relative] -> node
      true -> moved(node, namespace, module)
    end
  end

  defp rewrite({_kind, node, _module, _via}, _namespace, _modules, _moved_aliases), do: node

  defp moved({:__aliases__, meta, _parts}, namespace, module) do
    {:__aliases__, meta, Enum.map([namespace | Module.split(module)], &String.to_atom/1)}
  end

  defp split_grouped_aliases(ast) do
    Macro.prewalk(ast, fn
      {:alias, meta, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]} ->
        {:__block__, [],
         Enum.map(children, fn {:__aliases__, child_meta, parts} ->
           {:alias, meta, [{:__aliases__, child_meta, base ++ parts}]}
         end)}

      node ->
        node
    end)
  end

  # Calls `fun` with `{kind, node, module, via}` for each module name in `ast`,
  # where `module` is the name the compiler resolves it to.
  defp walk(ast, acc, fun) do
    state = %{scopes: [%{module: nil, aliases: %{}}], next_id: 0, acc: acc, fun: fun}
    {ast, state} = Macro.traverse(ast, state, &enter/2, &leave/2)
    {ast, state.acc}
  end

  defp enter({:defmodule, meta, [{:__aliases__, _, parts} = name | rest]}, state)
       when is_list(parts) do
    [scope | _] = state.scopes

    if Enum.all?(parts, &is_atom/1) do
      {name, module, state} =
        case scope.module do
          nil ->
            module = Module.concat(parts)
            {name, state} = emit(state, {:reference, name, module, :absolute})
            {name, module, state}

          outer ->
            implicit = Module.concat(outer, hd(parts))

            {name, Module.concat([outer | parts]),
             put_alias(state, hd(parts), implicit, :implicit)}
        end

      {_name, state} = emit(state, {:defmodule, name, module, nil})
      [scope | parents] = state.scopes
      state = %{state | scopes: [%{scope | module: module}, scope | parents]}
      {{:defmodule, meta, [skip(name) | rest]}, state}
    else
      {{:defmodule, meta, [name | rest]}, push_scope(state, nil)}
    end
  end

  defp enter({:alias, meta, [{:__aliases__, _, parts} = target | opts]}, state) do
    case resolve(parts, state) do
      {module, _via} ->
        id = state.next_id
        state = %{state | next_id: id + 1}
        {target, state} = emit(state, {:alias, target, module, {:alias, id}})
        state = put_alias(state, alias_name(opts, module), module, {:via, id})
        {{:alias, meta, [skip(target) | Macro.prewalk(opts, &skip/1)]}, state}

      :unknown ->
        {{:alias, meta, [target | opts]}, state}
    end
  end

  defp enter({:__aliases__, meta, parts} = node, state) do
    with false <- Keyword.get(meta, @skip, false),
         {module, via} <- resolve(parts, state) do
      {node, state} = emit(state, {:reference, node, module, via})
      {skip(node), state}
    else
      _skipped_or_unknown -> {node, state}
    end
  end

  defp enter(node, state), do: {node, state}

  defp leave({:defmodule, _meta, [{:__aliases__, _, _} | _]} = node, state) do
    {node, %{state | scopes: tl(state.scopes)}}
  end

  defp leave(node, state), do: {node, state}

  defp emit(state, event) do
    {node, acc} = state.fun.(event, state.acc)
    {node, %{state | acc: acc}}
  end

  defp push_scope(state, module) do
    [scope | _] = state.scopes
    %{state | scopes: [%{scope | module: module} | state.scopes]}
  end

  defp put_alias(state, name, module, via) do
    [scope | parents] = state.scopes
    %{state | scopes: [%{scope | aliases: Map.put(scope.aliases, name, {module, via})} | parents]}
  end

  defp resolve([:"Elixir" | parts], _state) when parts != [],
    do: {Module.concat(parts), :absolute}

  defp resolve([{:__MODULE__, _, _} | parts], state) do
    case hd(state.scopes).module do
      nil -> :unknown
      module -> {Module.concat([module | parts]), :relative}
    end
  end

  defp resolve([head | rest] = parts, state) when is_atom(head) do
    case Map.fetch(hd(state.scopes).aliases, head) do
      {:ok, {target, via}} -> {Module.concat([target | rest]), via}
      :error -> {Module.concat(parts), :absolute}
    end
  end

  defp resolve(_parts, _state), do: :unknown

  defp alias_name(opts, module) do
    Enum.find_value(List.flatten(opts), fn
      {:as, {:__aliases__, _, [name]}} -> name
      {{:__block__, _, [:as]}, {:__aliases__, _, [name]}} -> name
      _option -> nil
    end) || module |> Module.split() |> List.last() |> String.to_atom()
  end

  defp skip({:__aliases__, meta, parts}),
    do: {:__aliases__, Keyword.put(meta, @skip, true), parts}

  defp skip(node), do: node
end
