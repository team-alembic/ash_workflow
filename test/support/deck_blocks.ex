defmodule AshWorkflowTest.DeckBlocks do
  @moduledoc """
  Extracts the AshWorkflow DSL out of `slides/2026-ashconf-when-time-meets-state/deck.md`
  and compiles it.

  A slide is a code review nobody runs. The deck's DSL was written by hand and
  edited on the plane, so an option that never existed, or one renamed two
  releases ago, reads exactly as convincingly on a projector as the real thing.

  Every Elixir fence in the deck carries a tag in its info string, which no
  Markdown renderer displays:

      ```elixir ash_workflow:review
      ```elixir illustrative

  `ash_workflow:<fixture>` means the block is real DSL, and names the fixture in
  `@fixtures` that supplies the resource around it — the attributes, actions and
  neighbouring steps the excerpt refers to but does not show. `illustrative`
  means the block is something else: an `Ash.Query` pipeline, a hand-rolled
  AshOban trigger, output from `iex`. `AshWorkflow.DeckDslTest` fails on an
  untagged fence, so adding a slide forces the choice.

  A block referring to modules under `MyApp` has that prefix rewritten into a
  per-block namespace, so two slides can both name `MyApp.CandidateTransition`
  without redefining it.
  """

  @deck "slides/2026-ashconf-when-time-meets-state/deck.md"

  @rewritten_prefixes ["MyApp"]

  @fixture_defaults %{
    attributes: "",
    actions: "",
    steps: "",
    modules: "",
    workflow: "",
    workflow_options: "",
    authorizers: "[]"
  }

  # The transition log the `MyApp` slides configure, plus the actor their
  # `belongs_to_actor` names.
  @log_modules """
        defmodule MyApp.Recruiter do
          @moduledoc false
          use Ash.Resource,
            domain: AshWorkflowTest.DeckDomain,
            data_layer: Ash.DataLayer.Ets

          actions do
            defaults [:read]

            create :create do
              accept [:name]
            end
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :name, :string, public?: true
          end
        end

        defmodule MyApp.CandidateTransition do
          @moduledoc false
          use Ash.Resource,
            domain: AshWorkflowTest.DeckDomain,
            data_layer: Ash.DataLayer.Ets

          actions do
            defaults [:read]

            create :create do
              accept [
                :workflow_id,
                :undoes_id,
                :recruiter_id,
                :from_state,
                :to_state,
                :transition_name,
                :occurred_at,
                :triggered_by
              ]
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
            belongs_to :workflow, {{workflow}},
              allow_nil?: false,
              public?: true,
              attribute_public?: true,
              attribute_writable?: true

            belongs_to :undoes, __MODULE__,
              public?: true,
              attribute_public?: true,
              attribute_writable?: true

            belongs_to :recruiter, MyApp.Recruiter,
              public?: true,
              attribute_public?: true,
              attribute_writable?: true
          end
        end
  """

  # The surroundings each excerpt assumes. `modules` is source compiled ahead of
  # the resource, and `{{workflow}}` in it resolves to the resource's name.
  @fixtures %{
    "review" => %{
      workflow_options: "scheduler AshWorkflow.Scheduler.Precise"
    },
    "verifying" => %{
      attributes: """
      attribute :score, :integer, public?: true
      """,
      actions: """
      update :run_verification do
        accept []
      end
      """,
      steps: """
      step :review do
        transition :hire, to: :hired
      end
      """
    },
    # The timeout and every slides show those declarations on their own, so the
    # fixture supplies the step they sit in as well as the states they aim at.
    "timeouts" => %{
      actions: """
      update :send_review_reminder do
        accept []
      end
      """,
      workflow_options: "scheduler AshWorkflow.Scheduler.Precise",
      workflow: "step :review do\n  transition :hire, to: :hired\n{{block}}\nend"
    },
    "scheduler" => %{
      steps: """
      step :review do
        transition :hire, to: :hired
      end
      """
    },
    "policy" => %{
      authorizers: "[Ash.Policy.Authorizer]"
    },
    # The ATS slide shows the whole workflow, so the fixture supplies only the
    # field its conditional route reads and the actions its steps call.
    "ats_workflow" => %{
      attributes: """
      attribute :score, :integer, public?: true
      """,
      actions: """
      update :record_hr_screen do
        accept []
      end

      update :call_the_bureau do
        accept []
      end

      update :chase_dbs do
        accept []
      end
      """,
      workflow_options: "scheduler AshWorkflow.Scheduler.Precise"
    },
    "review_nudge" => %{
      actions: """
      update :send_review_reminder do
        accept []
      end
      """,
      workflow_options: "scheduler AshWorkflow.Scheduler.Precise"
    },
    # The transition log slide configures the log on its own, and a workflow
    # needs a step to log.
    "transition_log" => %{
      modules: @log_modules,
      steps: """
      step :review do
        transition :hire, to: :hired
      end
      """
    },
    # `same_actor?` needs the log to record who acted, and the undo slide shows
    # neither the log nor its `belongs_to_actor`.
    "undo" => %{
      workflow_options: """
      transition_log MyApp.CandidateTransition do
        belongs_to_actor :recruiter, MyApp.Recruiter
      end
      """,
      modules: @log_modules
    }
  }

  @doc "The deck's path, relative to the project root."
  def deck, do: @deck

  @doc "True when the deck is present in this checkout."
  def deck?, do: File.exists?(@deck)

  @doc """
  Every Elixir fence in the deck, as
  `%{line: integer, tag: String.t(), code: String.t()}`.
  """
  def blocks do
    @deck
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], nil}, &collect_fence/2)
    |> elem(0)
    |> Enum.reverse()
  end

  defp collect_fence({"```" <> info, line}, {blocks, nil}) do
    case String.split(info, " ", trim: true) do
      ["elixir" | rest] -> {blocks, %{line: line, tag: Enum.join(rest, " "), code: []}}
      _ -> {blocks, %{skip: true}}
    end
  end

  defp collect_fence({"```" <> _, _line}, {blocks, %{skip: true}}), do: {blocks, nil}

  defp collect_fence({"```" <> _, _line}, {blocks, open}) do
    {[%{open | code: open.code |> Enum.reverse() |> Enum.join("\n")} | blocks], nil}
  end

  defp collect_fence({_line_text, _line}, {blocks, nil}), do: {blocks, nil}
  defp collect_fence({_line_text, _line}, {blocks, %{skip: true} = open}), do: {blocks, open}

  defp collect_fence({line_text, _line}, {blocks, open}) do
    {blocks, %{open | code: [line_text | open.code]}}
  end

  @doc "The fixture names `@fixtures` knows about."
  def fixture_names, do: Map.keys(@fixtures)

  @doc """
  Compiles a block against its fixture, returning the verifier errors the DSL
  produced.

  Spark runs its verifiers from `@after_verify`, and downgrades anything they
  raise to a compiler warning, so a broken slide would compile with a message
  scrolling past. Setting `{Spark.Dsl, :test_collector}` in the process
  dictionary makes Spark send its errors as messages instead, so each module is
  verified again here, in this process, where the errors can be collected and
  asserted on.
  """
  def compile(%{line: line, tag: tag, code: code}) do
    "ash_workflow:" <> fixture_name = tag
    fixture = Map.merge(@fixture_defaults, Map.fetch!(@fixtures, fixture_name))
    namespace = "AshWorkflowTest.Deck.Block#{line}"

    source = source(namespace, fixture, code)

    # `with_diagnostics` collects the compiler's warnings instead of printing
    # them. Ash defines an `Inspect` implementation per resource, and the
    # protocol is already consolidated by the time the tests run, so each block
    # would otherwise print a warning nobody can act on.
    {modules, _diagnostics} =
      Code.with_diagnostics(fn -> Code.compile_string(source, "#{@deck}:#{line}") end)

    Process.put({Spark.Dsl, :test_collector}, self())

    Enum.each(modules, fn {module, _bytecode} ->
      # AshWorkflow generates Oban worker and scheduler modules into the
      # resource. They are not Spark modules, so there is nothing to verify.
      if Code.ensure_loaded?(module) and function_exported?(module, :__verify_spark_dsl__, 1) do
        module.__verify_spark_dsl__(module)
      end
    end)

    Process.delete({Spark.Dsl, :test_collector})

    verifier_errors()
  end

  defp verifier_errors(collected \\ []) do
    receive do
      {Spark.Dsl, :verifier_errors, module, errors} ->
        verifier_errors(collected ++ Enum.map(errors, &{module, &1}))
    after
      0 -> collected
    end
  end

  defp source(namespace, fixture, code) do
    resource = "#{namespace}.Workflow"

    """
    #{rewrite(fixture.modules, namespace, resource)}

    defmodule #{resource} do
      @moduledoc false
      use Ash.Resource,
        domain: AshWorkflowTest.DeckDomain,
        data_layer: Ash.DataLayer.Ets,
        authorizers: #{fixture.authorizers},
        extensions: [AshWorkflow, AshOban]

      workflow do
        #{workflow_body(fixture, code, namespace, resource)}
      end

      actions do
        defaults [:read]

        create :create do
          accept []
        end

        #{fixture.actions}
      end

      attributes do
        uuid_v7_primary_key :id
        #{fixture.attributes}
      end
    end
    """
  end

  # A block either opens with `workflow do`, in which case its body is spliced
  # into the fixture's, or it is a step or a bare timeout, which the fixture's
  # `workflow` template places inside one.
  defp workflow_body(fixture, code, namespace, resource) do
    template = if fixture.workflow == "", do: "{{block}}", else: fixture.workflow

    body =
      case String.split(code, "\n", trim: true) do
        ["workflow do" | _] -> unwrap(code)
        _ -> String.replace(template, "{{block}}", code)
      end

    declared = "#{fixture.workflow_options}\n\n#{body}\n\n#{fixture.steps}"

    rewrite("#{declared}\n#{terminal_steps_for(declared)}", namespace, resource)
  end

  # An excerpt names the states it leaves for without declaring them — that is
  # what makes it an excerpt. Every state a transition, route or timeout aims at
  # and nothing declares becomes a terminal step, so the excerpt's own routing
  # is what the verifiers see rather than the fixture's guess at it.
  @route_patterns [
    ~r/\bto:\s+:(\w+)/,
    ~r/\btransition_to:?\s+:(\w+)/,
    ~r/\bon_success\s+:(\w+)/,
    ~r/\bon_error\s+:(\w+)/
  ]

  defp terminal_steps_for(workflow_body) do
    declared =
      ~r/\bstep\s+:(\w+)/
      |> Regex.scan(workflow_body)
      |> MapSet.new(fn [_match, name] -> name end)

    @route_patterns
    |> Enum.flat_map(&(&1 |> Regex.scan(workflow_body) |> Enum.map(fn [_, name] -> name end)))
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(declared, &1))
    |> Enum.map_join("\n", &"step :#{&1}, terminal: true")
  end

  defp unwrap(code) do
    lines = String.split(code, "\n")

    lines
    |> Enum.slice(1..-2//1)
    |> Enum.join("\n")
  end

  defp rewrite(source, namespace, resource) do
    source = String.replace(source, "{{workflow}}", resource)

    Enum.reduce(@rewritten_prefixes, source, fn prefix, acc ->
      String.replace(acc, prefix <> ".", "#{namespace}.#{prefix}.")
    end)
  end
end
