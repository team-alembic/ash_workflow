defmodule Mix.Tasks.AshWorkflow.Gen.TransitionLog.Docs do
  @moduledoc false

  def short_doc do
    "Scaffolds a transition log resource for a workflow"
  end

  def example do
    "mix ash_workflow.gen.transition_log MyApp.Ticket"
  end

  def long_doc do
    """
    #{short_doc()}

    Generates a sibling resource that satisfies
    `AshWorkflow.Verifiers.ValidateTransitionLog`, registers it in the
    workflow resource's domain, and — where it can do so safely — adds the
    matching `transition_log` entry to the workflow resource's `workflow`
    block.

    The generated resource uses the same data layer as the workflow resource
    (`Ash.DataLayer.Ets` or `AshPostgres.DataLayer`, reusing the workflow's
    configured repo on Postgres).

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--log-module` - the module name for the generated log resource.
      Defaults to the workflow module's name with `Transition` appended, e.g.
      `MyApp.Ticket` becomes `MyApp.TicketTransition`.
    * `--actor` - an actor resource module. When given, the generated log
      resource gets a `belongs_to` relationship to it and the workflow's
      `transition_log` block gets a matching `belongs_to_actor` entry.
    """
  end
end

# Guarded on the struct this task builds rather than on `Igniter` itself.
# `Code.ensure_loaded?(Igniter)` can be true during a cold parallel build while
# `Igniter.Mix.Task.Info` has not been written yet, and since Elixir 1.19 the
# type checker turns a reference to an unavailable struct into a compile
# error rather than a warning — which broke every demo that depends on this
# library by path. Ensuring the struct module specifically both tests for it
# and loads it.
if Code.ensure_loaded?(Igniter.Mix.Task.Info) do
  defmodule Mix.Tasks.AshWorkflow.Gen.TransitionLog do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"
    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Ash.Domain.Igniter, as: DomainIgniter
    alias Ash.Resource.Igniter, as: ResourceIgniter
    alias Igniter.Project.Module, as: ProjectModule
    alias Mix.AshWorkflow.Recipe

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example: __MODULE__.Docs.example(),
        positional: [:resource],
        schema: [log_module: :string, actor: :string]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      workflow_module = ProjectModule.parse(igniter.args.positional.resource)

      case Code.ensure_compiled(workflow_module) do
        {:module, _module} ->
          generate(igniter, workflow_module, compiled_resource(workflow_module))

        {:error, reason} ->
          case source_resource(igniter, workflow_module) do
            {:ok, igniter, resource} -> generate(igniter, workflow_module, resource)
            {:error, igniter} -> compile_error(igniter, workflow_module, reason)
          end
      end
    end

    defp compile_error(igniter, workflow_module, reason) do
      Igniter.add_issue(
        igniter,
        "Could not load #{inspect(workflow_module)} (#{inspect(reason)}). " <>
          "It must already exist and compile before generating its transition log."
      )
    end

    defp compiled_resource(workflow_module) do
      if AshWorkflow.Info.workflow?(workflow_module),
        do: compiled_workflow(workflow_module),
        else: %{workflow?: false}
    end

    defp compiled_workflow(workflow_module) do
      data_layer = Ash.Resource.Info.data_layer(workflow_module)

      %{
        workflow?: true,
        transition_log?: AshWorkflow.Info.transition_log(workflow_module) != nil,
        domain: Ash.Resource.Info.domain(workflow_module),
        data_layer: data_layer,
        postgres: compiled_postgres(workflow_module, data_layer)
      }
    end

    defp compiled_postgres(workflow_module, AshPostgres.DataLayer) do
      # Resolved at runtime: ash_postgres is a dev/test-only dependency of this
      # library, so referencing it directly warns in every consuming project.
      info = Module.concat(["AshPostgres", "DataLayer", "Info"])
      %{table: info.table(workflow_module), repo: info.repo(workflow_module)}
    end

    defp compiled_postgres(_workflow_module, _data_layer), do: nil

    # A resource generated earlier in the same Igniter run, such as the one
    # `ash_workflow.gen.approval` writes, exists only as source. Igniter marks
    # a file it read from disk `from: :file`, so a source not from a file was
    # created in this run. A file from disk that did not load failed to compile.
    defp source_resource(igniter, workflow_module) do
      with {:ok, {igniter, source, zipper}} <- ProjectModule.find_module(igniter, workflow_module),
           false <- Rewrite.Source.from?(source, :file) do
        body =
          zipper |> Sourceror.Zipper.node() |> Sourceror.to_string() |> Code.string_to_quoted!()

        {:ok, igniter, resource_from_ast(body)}
      else
        {:error, igniter} -> {:error, igniter}
        true -> {:error, igniter}
      end
    end

    defp resource_from_ast(body) do
      use_opts = find_call(body, :use, &match?([{:__aliases__, _, [:Ash, :Resource]}, _], &1))
      opts = if use_opts, do: List.last(use_opts), else: []
      data_layer = ast_module(opts[:data_layer]) || Ash.DataLayer.Simple

      %{
        workflow?: AshWorkflow in Enum.map(List.wrap(opts[:extensions]), &ast_module/1),
        transition_log?: find_call(block(body, :workflow), :transition_log) != nil,
        domain: ast_module(opts[:domain]),
        data_layer: data_layer,
        postgres: source_postgres(body, data_layer)
      }
    end

    defp source_postgres(body, AshPostgres.DataLayer) do
      postgres = block(body, :postgres)
      [table] = find_call(postgres, :table) || [nil]
      [repo] = find_call(postgres, :repo) || [nil]
      %{table: table, repo: ast_module(repo)}
    end

    defp source_postgres(_body, _data_layer), do: nil

    defp block(body, name) do
      case find_call(body, name) do
        [[do: block]] -> block
        _ -> nil
      end
    end

    defp find_call(ast, name, match? \\ fn _args -> true end) do
      {_ast, found} =
        Macro.prewalk(ast, nil, fn
          {^name, _, args} = node, nil when is_list(args) ->
            if match?.(args), do: {node, args}, else: {node, nil}

          node, found ->
            {node, found}
        end)

      found
    end

    defp ast_module({:__aliases__, _, parts}), do: Module.concat(parts)
    defp ast_module(_other), do: nil

    defp generate(igniter, workflow_module, %{workflow?: true} = resource) do
      case actor_config(igniter.args.options[:actor]) do
        {:ok, actor} -> generate_log(igniter, workflow_module, resource, actor)
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp generate(igniter, workflow_module, _resource) do
      Igniter.add_issue(
        igniter,
        "#{inspect(workflow_module)} does not use the AshWorkflow extension."
      )
    end

    defp generate_log(igniter, workflow_module, resource, actor) do
      log_module = log_module(workflow_module, igniter.args.options[:log_module])

      igniter
      |> ProjectModule.create_module(
        log_module,
        resource_contents(workflow_module, resource, log_module, actor)
      )
      |> then(fn igniter ->
        if resource.domain,
          do: DomainIgniter.add_resource_reference(igniter, resource.domain, log_module),
          else: igniter
      end)
      |> add_transition_log_entry(workflow_module, resource, log_module, actor)
      |> Igniter.add_notice("""
      Generated #{inspect(log_module)} as the transition log for #{inspect(workflow_module)}.

      Run `mix ash.codegen add_#{Macro.underscore(log_module_basename(log_module))}` \
      (Postgres only) to generate its migration, then `mix ash_workflow.backfill_transition_log \
      #{inspect(workflow_module)}` to seed an approximate `:initial` row for existing records.
      """)
    end

    defp log_module(workflow_module, nil) do
      workflow_module
      |> Module.split()
      |> List.update_at(-1, &(&1 <> "Transition"))
      |> Module.concat()
    end

    defp log_module(_workflow_module, log_module), do: ProjectModule.parse(log_module)

    defp log_module_basename(module) do
      module |> Module.split() |> List.last()
    end

    defp actor_config(nil), do: {:ok, nil}

    # The actor foreign key takes the type of the actor's primary key, so an
    # actor with an integer key gets an integer column.
    defp actor_config(actor_module_string) do
      actor_module = ProjectModule.parse(actor_module_string)

      name =
        actor_module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()

      with {:ok, key_type} <- Recipe.key_type(actor_module, "transition log", nil) do
        {:ok, %{name: name, destination: actor_module, key_type: key_type}}
      end
    end

    defp add_transition_log_entry(igniter, workflow_module, resource, log_module, actor) do
      if resource.transition_log? do
        Igniter.add_warning(igniter, """
        #{inspect(workflow_module)} already has a `transition_log` configured. \
        Skipping the DSL update — add the following yourself if you meant to point it at \
        #{inspect(log_module)}:

        #{transition_log_snippet(log_module, actor)}
        """)
      else
        ResourceIgniter.add_block(
          igniter,
          workflow_module,
          :workflow,
          transition_log_snippet(log_module, actor)
        )
      end
    end

    defp transition_log_snippet(log_module, nil) do
      "transition_log #{inspect(log_module)}"
    end

    defp transition_log_snippet(log_module, actor) do
      """
      transition_log #{inspect(log_module)} do
        belongs_to_actor :#{actor.name}, #{inspect(actor.destination)}
      end
      """
    end

    defp resource_contents(workflow_module, resource, log_module, actor) do
      """
      use Ash.Resource,
        domain: #{inspect(resource.domain)},
        data_layer: #{inspect(resource.data_layer)}

      #{data_layer_block(resource, log_module)}

      actions do
        defaults [:read]

        create :create do
          accept #{inspect(accepted_attributes(actor))}
        end
      end

      attributes do
        uuid_v7_primary_key :id
        attribute :from_state, :atom, public?: true
        attribute :to_state, :atom, allow_nil?: false, public?: true
        attribute :transition_name, :atom, allow_nil?: false, public?: true
        attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
        attribute :triggered_by, :atom, allow_nil?: false, public?: true
      end

      relationships do
        belongs_to :workflow, #{inspect(workflow_module)},
          allow_nil?: false,
          public?: true,
          attribute_public?: true,
          attribute_writable?: true

        # Set on an undo row, pointing at the row it reverses. Undo appends
        # rather than mutating, so the reversed row stays exactly as written
        # and both readings of history stay derivable from the same rows.
        belongs_to :undoes, __MODULE__,
          allow_nil?: true,
          public?: true,
          attribute_public?: true,
          attribute_writable?: true

        #{actor_relationship(actor)}
      end
      """
    end

    defp accepted_attributes(nil) do
      [
        :workflow_id,
        :undoes_id,
        :from_state,
        :to_state,
        :transition_name,
        :occurred_at,
        :triggered_by
      ]
    end

    defp accepted_attributes(actor) do
      accepted_attributes(nil) ++ [:"#{actor.name}_id"]
    end

    defp actor_relationship(nil), do: ""

    defp actor_relationship(actor) do
      """
      belongs_to :#{actor.name}, #{inspect(actor.destination)},
        #{attribute_type(actor.key_type)}allow_nil?: true,
        public?: true,
        attribute_public?: true,
        attribute_writable?: true
      """
    end

    defp attribute_type(nil), do: ""
    defp attribute_type(type), do: "attribute_type: #{inspect(type)},\n"

    defp data_layer_block(%{postgres: %{table: table, repo: repo}}, log_module) do
      """
      postgres do
        table #{inspect(log_table_name(table, log_module))}
        repo #{inspect(repo)}

        custom_indexes do
          index [:workflow_id, :occurred_at]
        end
      end
      """
    end

    defp data_layer_block(_resource, _log_module), do: ""

    defp log_table_name(nil, log_module) do
      log_module |> Module.split() |> List.last() |> Macro.underscore() |> Kernel.<>("s")
    end

    defp log_table_name(workflow_table, _log_module), do: "#{workflow_table}_transitions"
  end
else
  defmodule Mix.Tasks.AshWorkflow.Gen.TransitionLog do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_workflow.gen.transition_log' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
