# Guarded on the struct the recipe tasks build rather than on `Igniter` itself.
# See `Mix.Tasks.AshWorkflow.Gen.TransitionLog` for why.
if Code.ensure_loaded?(Igniter.Mix.Task.Info) do
  defmodule Mix.AshWorkflow.Recipe do
    @moduledoc false

    alias Ash.Resource.Igniter, as: ResourceIgniter
    alias Ash.Resource.Info, as: ResourceInfo
    alias Igniter.Project.Module, as: ProjectModule

    @type storage :: %{domain: module(), data_layer: module(), repo: module() | nil}

    @spec parse_duration(String.t() | nil, String.t()) ::
            {:ok, AshWorkflow.Duration.t() | nil} | {:error, String.t()}
    def parse_duration(nil, _flag), do: {:ok, nil}

    def parse_duration(value, flag) do
      case Regex.run(~r/^([1-9]\d*)([mhdw])$/, value) do
        [_match, count, unit] -> {:ok, duration(String.to_integer(count), unit)}
        nil -> {:error, "#{flag} must look like 30m, 12h, 2d or 2w, got: #{value}"}
      end
    end

    defp duration(count, "m"), do: {count, :minutes}
    defp duration(count, "h"), do: {count, :hours}
    defp duration(count, "d"), do: {count, :days}
    defp duration(count, "w"), do: {count * 7, :days}

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
    same name is already there, in which case it warns and leaves that one as
    it is.
    """
    @spec add_subject_edits(Igniter.t(), module(), keyword(String.t()), keyword(String.t())) ::
            Igniter.t()
    def add_subject_edits(igniter, subject, relationships, calculations) do
      igniter =
        Enum.reduce(relationships, igniter, fn edit, igniter ->
          add_subject_edit(
            igniter,
            subject,
            edit,
            "relationship",
            &ResourceIgniter.defines_relationship/3,
            &ResourceIgniter.add_relationship/3
          )
        end)

      Enum.reduce(calculations, igniter, fn edit, igniter ->
        add_subject_edit(
          igniter,
          subject,
          edit,
          "calculation",
          &ResourceIgniter.defines_calculation/3,
          &ResourceIgniter.add_calculation/3
        )
      end)
    end

    defp add_subject_edit(igniter, subject, {name, code}, kind, defines, add) do
      case defines.(igniter, subject, name) do
        {igniter, true} ->
          Igniter.add_warning(igniter, """
          #{inspect(subject)} already has a #{kind} named #{inspect(name)}, so the recipe left it as it is. It would have added:

          #{code}
          """)

        {igniter, false} ->
          add.(igniter, subject, code)
      end
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
