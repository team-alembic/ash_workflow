# Guarded on the struct the recipe tasks build rather than on `Igniter` itself.
# See `Mix.Tasks.AshWorkflow.Gen.TransitionLog` for why.
if Code.ensure_loaded?(Igniter.Mix.Task.Info) do
  defmodule Mix.AshWorkflow.Recipe do
    @moduledoc false

    alias Ash.Resource.Igniter, as: ResourceIgniter
    alias Ash.Resource.Info, as: ResourceInfo
    alias Igniter.Code.Common
    alias Igniter.Code.Function, as: CodeFunction
    alias Igniter.Project.Module, as: ProjectModule

    @type storage :: %{domain: module(), data_layer: module(), repo: module() | nil}

    @spec parse_duration(String.t() | nil, String.t()) ::
            {:ok, AshWorkflow.Duration.t() | nil} | {:error, String.t()}
    def parse_duration(nil, _flag), do: {:ok, nil}

    def parse_duration(value, flag) do
      case Regex.run(~r/^([1-9]\d*)([smhdw])$/, value) do
        [_match, count, unit] -> {:ok, duration(String.to_integer(count), unit)}
        nil -> {:error, "#{flag} must look like 10s, 30m, 12h, 2d or 2w, got: #{value}"}
      end
    end

    defp duration(count, "s"), do: {count, :seconds}

    defp duration(count, "m"), do: {count, :minutes}
    defp duration(count, "h"), do: {count, :hours}
    defp duration(count, "d"), do: {count, :days}
    defp duration(count, "w"), do: {count * 7, :days}

    @doc "Accepts a `--max-attempts` value only when it is a positive integer."
    @spec validate_max_attempts(term()) :: :ok | {:error, String.t()}
    def validate_max_attempts(count) when is_integer(count) and count >= 1, do: :ok

    def validate_max_attempts(count),
      do: {:error, "--max-attempts must be a positive integer, got: #{inspect(count)}"}

    @doc """
    Resolves where the recipe's resources are stored, composing
    `ash.gen.resource` first when the subject does not exist.

    A created subject takes its data layer from the first of `sources`, then of
    the `--domain` resources, that uses ETS or Postgres. When none does, the
    task stops with an issue rather than create a subject that cannot store
    records.
    """
    @spec ensure_subject(Igniter.t(), module(), String.t() | nil, String.t(), [module()]) ::
            {:ok, Igniter.t(), storage()} | {:error, Igniter.t()}
    def ensure_subject(igniter, subject, domain, recipe, sources) do
      {exists?, igniter} = ProjectModule.module_exists(igniter, subject)

      cond do
        exists? ->
          existing_subject(igniter, subject, recipe)

        domain ->
          missing_subject(igniter, subject, ProjectModule.parse(domain), sources)

        true ->
          {:error,
           Igniter.add_issue(
             igniter,
             "#{inspect(subject)} does not exist. Pass --domain to create it."
           )}
      end
    end

    defp existing_subject(igniter, subject, recipe) do
      case Code.ensure_compiled(subject) do
        {:module, _module} ->
          stored_subject(igniter, subject, recipe)

        {:error, reason} ->
          {:error,
           Igniter.add_issue(
             igniter,
             "Could not load #{inspect(subject)} (#{inspect(reason)}). " <>
               "An existing subject must compile before adding #{recipe} to it."
           )}
      end
    end

    defp stored_subject(igniter, subject, recipe) do
      case storage(subject, ResourceInfo.domain(subject)) do
        %{data_layer: Ash.DataLayer.Simple} ->
          {:error,
           Igniter.add_issue(
             igniter,
             "#{inspect(subject)} has no data layer, so a #{recipe} resource beside it " <>
               "could not store records. Give #{inspect(subject)} a data layer first."
           )}

        storage ->
          {:ok, igniter, storage}
      end
    end

    defp missing_subject(igniter, subject, domain, sources) do
      case Enum.find(sources ++ domain_resources(domain), &known_data_layer?/1) do
        nil ->
          {:error,
           Igniter.add_issue(
             igniter,
             "#{inspect(subject)} does not exist, and no ETS or Postgres resource was found " <>
               "to copy a data layer from. Create #{inspect(subject)} first, or pass a " <>
               "--domain that has an ETS or Postgres resource."
           )}

        resource ->
          storage = storage(resource, domain)

          igniter =
            Igniter.compose_task(igniter, "ash.gen.resource", [
              inspect(subject),
              "--uuid-v7-primary-key",
              "id",
              "--timestamps",
              "--default-actions",
              "read,create,update,destroy",
              "--domain",
              inspect(domain),
              "--extend",
              extension(storage.data_layer)
            ])

          {:ok, igniter, storage}
      end
    end

    defp domain_resources(domain) do
      case Code.ensure_compiled(domain) do
        {:module, _module} -> Ash.Domain.Info.resources(domain)
        {:error, _reason} -> []
      end
    end

    defp known_data_layer?(resource) do
      match?({:module, _module}, Code.ensure_compiled(resource)) and
        ResourceInfo.data_layer(resource) in [Ash.DataLayer.Ets, AshPostgres.DataLayer]
    end

    defp extension(Ash.DataLayer.Ets), do: "ets"
    defp extension(AshPostgres.DataLayer), do: "postgres"

    defp storage(resource, domain) do
      data_layer = ResourceInfo.data_layer(resource)
      %{domain: domain, data_layer: data_layer, repo: repo(resource, data_layer)}
    end

    defp repo(resource, AshPostgres.DataLayer) do
      # Resolved at runtime: ash_postgres is a dev/test-only dependency of this
      # library, so referencing it directly warns in every consuming project.
      Module.concat(["AshPostgres", "DataLayer", "Info"]).repo(resource)
    end

    defp repo(_resource, _data_layer), do: nil

    @doc """
    Adds each relationship and calculation to the subject unless one of the
    same name is already there. It warns when that existing one is not the
    recipe's: a relationship to another resource, or a calculation with
    another expression.
    """
    @spec add_subject_edits(Igniter.t(), module(), keyword(String.t()), keyword(String.t())) ::
            Igniter.t()
    def add_subject_edits(igniter, subject, relationships, calculations) do
      igniter =
        Enum.reduce(relationships, igniter, fn {name, code}, igniter ->
          add_subject_edit(
            igniter,
            subject,
            {name, code},
            {:relationships, [:has_one, :has_many, :belongs_to, :many_to_many], [2, 3, 4]},
            &same_destination?/2,
            &ResourceIgniter.add_relationship/3
          )
        end)

      Enum.reduce(calculations, igniter, fn {name, code}, igniter ->
        add_subject_edit(
          igniter,
          subject,
          {name, code},
          {:calculations, [:calculate], [3, 4, 5]},
          &same_definition?/2,
          &ResourceIgniter.add_calculation/3
        )
      end)
    end

    defp add_subject_edit(igniter, subject, {name, code}, location, same?, add) do
      case existing_definition(igniter, subject, name, location) do
        {igniter, {:ok, zipper}} ->
          if same?.(zipper, Sourceror.parse_string!(code)),
            do: igniter,
            else: warn_existing(igniter, subject, name, location, code)

        {igniter, :error} ->
          add.(igniter, subject, code)
      end
    end

    defp existing_definition(igniter, subject, name, {section, calls, arities}) do
      igniter
      |> Spark.Igniter.find(subject, fn _module, zipper ->
        with {:ok, zipper} <-
               CodeFunction.move_to_function_call_in_current_scope(zipper, section, 1),
             {:ok, zipper} <- Common.move_to_do_block(zipper) do
          Enum.find_value(calls, :error, &find_named_call(zipper, &1, arities, name))
        end
      end)
      |> case do
        {:ok, igniter, _module, zipper} -> {igniter, {:ok, zipper}}
        {:error, igniter} -> {igniter, :error}
      end
    end

    defp find_named_call(zipper, call, arities, name) do
      case CodeFunction.move_to_function_call_in_current_scope(
             zipper,
             call,
             arities,
             &CodeFunction.argument_equals?(&1, 0, name)
           ) do
        {:ok, zipper} -> {:ok, zipper}
        :error -> nil
      end
    end

    defp same_destination?(zipper, {_call, _meta, [_name, {:__aliases__, _, parts} | _rest]}) do
      case CodeFunction.move_to_nth_argument(zipper, 1) do
        {:ok, destination} -> Common.nodes_equal?(destination, Module.concat(parts))
        :error -> false
      end
    end

    defp same_definition?(zipper, recipe_ast) do
      without_meta(Sourceror.Zipper.node(zipper)) == without_meta(recipe_ast)
    end

    defp without_meta(ast) do
      Macro.prewalk(ast, fn
        {form, _meta, args} -> {form, [], args}
        other -> other
      end)
    end

    defp warn_existing(igniter, subject, name, {section, _calls, _arities}, code) do
      kind = section |> Atom.to_string() |> String.trim_trailing("s")

      Igniter.add_warning(igniter, """
      #{inspect(subject)} already has a #{kind} named #{inspect(name)} that differs from the recipe's, so the recipe left it as it is. It would have added:

      #{code}
      """)
    end

    @spec compose_transition_log(Igniter.t(), module(), module() | nil) :: Igniter.t()
    def compose_transition_log(igniter, workflow, nil) do
      Igniter.compose_task(igniter, "ash_workflow.gen.transition_log", [inspect(workflow)])
    end

    def compose_transition_log(igniter, workflow, actor) do
      Igniter.compose_task(igniter, "ash_workflow.gen.transition_log", [
        inspect(workflow),
        "--actor",
        inspect(actor)
      ])
    end

    @doc """
    Returns the type a foreign key to `resource` should take, from its
    single-field primary key, or `missing` when `resource` does not compile.
    """
    @spec key_type(module(), String.t(), atom() | nil) ::
            {:ok, atom() | nil} | {:error, String.t()}
    def key_type(resource, recipe, missing) do
      case Code.ensure_compiled(resource) do
        {:module, _module} -> compiled_key_type(resource, recipe)
        {:error, _reason} -> {:ok, missing}
      end
    end

    defp compiled_key_type(resource, recipe) do
      case ResourceInfo.primary_key(resource) do
        [field] ->
          type = ResourceInfo.attribute(resource, field).type
          {:ok, Enum.find_value(Ash.Type.short_names(), type, &short_name(&1, type))}

        fields ->
          {:error,
           "#{inspect(resource)} has a composite primary key #{inspect(fields)}. " <>
             "The #{recipe} resource can only belong to a resource with a single-field primary key."}
      end
    end

    defp short_name({name, type}, type), do: name
    defp short_name(_entry, _type), do: nil

    @doc """
    Returns a required, public `belongs_to` whose foreign key takes
    `key_type`, or Ash's default type when `key_type` is `nil`.
    """
    @spec belongs_to(atom(), module(), atom() | nil) :: String.t()
    def belongs_to(name, destination, key_type) do
      "belongs_to #{inspect(name)}, #{inspect(destination)}, allow_nil?: false, public?: true" <>
        attribute_type(key_type)
    end

    defp attribute_type(nil), do: ""
    defp attribute_type(type), do: ", attribute_type: #{inspect(type)}"

    @doc """
    Returns the source of a policy check that denies every actor until the
    application replaces its `match?/3`.
    """
    @spec deny_check_contents(String.t(), String.t()) :: String.t()
    def deny_check_contents(purpose, description) do
      """
      @moduledoc \"\"\"
      #{purpose}

      Denies everyone until the application replaces `match?/3`.
      \"\"\"

      use Ash.Policy.SimpleCheck

      @impl true
      def describe(_opts), do: #{inspect(description)}

      @impl true
      def match?(_actor, _context, _opts), do: false
      """
    end

    @doc "Returns a policy that authorizes `action` only when `check` passes."
    @spec create_policy(atom(), module()) :: String.t()
    def create_policy(action, check) do
      """
      policy action(#{inspect(action)}) do
        authorize_if #{inspect(check)}
      end
      """
    end

    # Two updates of one record would otherwise both read it before either
    # writes. The lock's before_action runs ahead of any change listed after it.
    @spec lock_for_update(storage()) :: String.t()
    def lock_for_update(%{data_layer: AshPostgres.DataLayer}),
      do: "change get_and_lock_for_update()\n"

    def lock_for_update(_storage), do: ""

    @spec pre_check_with(storage()) :: String.t()
    def pre_check_with(%{data_layer: AshPostgres.DataLayer}), do: ""
    def pre_check_with(storage), do: ", pre_check_with: #{inspect(storage.domain)}"

    @spec data_layer_option(storage()) :: String.t()
    def data_layer_option(%{data_layer: data_layer}), do: "data_layer: #{inspect(data_layer)},"

    @spec postgres_block(storage(), module(), String.t()) :: String.t()
    def postgres_block(storage, module, extra \\ "")

    def postgres_block(%{data_layer: AshPostgres.DataLayer, repo: repo}, module, extra) do
      """
      postgres do
        table #{inspect(table_name(module))}
        repo #{inspect(repo)}
        #{extra}
      end
      """
    end

    def postgres_block(_storage, _module, _extra), do: ""

    # Postgres truncates identifiers past 63 bytes, and AshPostgres rejects an
    # identity whose default index name would be truncated.
    @spec identity_index_name(module(), atom()) :: String.t()
    def identity_index_name(module, identity) do
      suffix = "_#{identity}_index"
      table = table_name(module)
      max_table_bytes = 63 - byte_size(suffix)

      if byte_size(table) > max_table_bytes do
        name = binary_part(table, 0, max_table_bytes) <> suffix
        "identity_index_names #{identity}: #{inspect(name)}"
      else
        ""
      end
    end

    defp table_name(module) do
      module |> Module.split() |> List.last() |> Macro.underscore() |> plural()
    end

    defp plural(name) do
      cond do
        Regex.match?(~r/[^aeiou]y$/, name) -> String.replace_suffix(name, "y", "ies")
        Regex.match?(~r/(s|x|z|ch|sh)$/, name) -> name <> "es"
        true -> name <> "s"
      end
    end
  end
end
