<!-- usage-rules-start -->
<!-- ash-start -->
## ash usage
_A declarative, extensible framework for building Elixir applications._

# Rules for working with Ash

## Understanding Ash

Ash is an opinionated, composable framework for building applications in Elixir. It provides a declarative approach to modeling your domain with resources at the center. Read documentation  *before* attempting to use its features. Do not assume that you have prior knowledge of the framework or its conventions.


<!-- ash-end -->
<!-- ash:actions-start -->
## ash:actions usage
# Actions

- Create specific, well-named actions rather than generic ones
- Put all business logic inside action definitions
- Use hooks like `Ash.Changeset.after_action/2`, `Ash.Changeset.before_action/2` to add additional logic
  inside the same transaction.
- Use hooks like `Ash.Changeset.after_transaction/2`, `Ash.Changeset.before_transaction/2` to add additional logic
  outside the transaction.
- Use action arguments for inputs that need validation
- Use preparations to modify queries before execution
- Preparations support `where` clauses for conditional execution
- Use `only_when_valid?` to skip preparations when the query is invalid
- Use changes to modify changesets before execution
- Use validations to validate changesets before execution
- Prefer domain code interfaces to call actions instead of directly building queries/changesets and calling functions in the `Ash` module
- A resource could be *only generic actions*. This can be useful when you are using a resource only to model behavior.
- Instead of defining functions in the domain, you should be defining actions and exposing them through code interface calls in the domain. Use standard actions when they fit what you're doing and generic actions when you need arbitrary functionality.

## Error Handling

Functions to call actions, like `Ash.create` and code interfaces like `MyApp.Accounts.register_user` all return ok/error tuples. All have `!` variations, like `Ash.create!` and `MyApp.Accounts.register_user!`. Use the `!` variations when you want to "let it crash", like if looking something up that should definitely exist, or calling an action that should always succeed. Always prefer the raising `!` variation over something like `{:ok, user} = MyApp.Accounts.register_user(...)`.

All Ash code returns errors in the form of `{:error, error_class}`. Ash categorizes errors into four main classes:

1. **Forbidden** (`Ash.Error.Forbidden`) - Occurs when a user attempts an action they don't have permission to perform
2. **Invalid** (`Ash.Error.Invalid`) - Occurs when input data doesn't meet validation requirements
3. **Framework** (`Ash.Error.Framework`) - Occurs when there's an issue with how Ash is being used
4. **Unknown** (`Ash.Error.Unknown`) - Occurs for unexpected errors that don't fit the other categories

These error classes help you catch and handle errors at an appropriate level of granularity. An error class will always be the "worst" (highest in the above list) error class from above. Each error class can contain multiple underlying errors, accessible via the `errors` field on the exception.

## Using Validations

Validations ensure that data meets your business requirements before it gets processed by an action. Unlike changes, validations cannot modify the changeset - they can only validate it or add errors.

Validations work on both changesets and queries. Built-in validations that support queries include:
- `action_is`, `argument_does_not_equal`, `argument_equals`, `argument_in`
- `byte_size`, `compare`, `confirm`, `match`, `negate`, `one_of`, `present`, `string_length`
- Custom validations that implement the `supports/1` callback

Common validation patterns:

```elixir
# Built-in validations with custom messages
validate compare(:age, greater_than_or_equal_to: 18) do
  message "You must be at least 18 years old"
end
validate match(:email, "@")
validate one_of(:status, [:active, :inactive, :pending])

# Conditional validations with where clauses
validate present(:phone_number) do
  where present(:contact_method) and eq(:contact_method, "phone")
end

# only_when_valid? - skip validation if prior validations failed
validate expensive_validation() do
  only_when_valid? true
end

# Action-specific vs global validations
actions do
  create :sign_up do
    validate present([:email, :password])  # Only for this action
  end
  
  read :search do
    argument :email, :string
    validate match(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)  # Validates query arguments
  end
end

validations do
  validate present([:title, :body]), on: [:create, :update]  # Multiple actions
end
```

- Create **custom validation modules** for complex validation logic:
  ```elixir
  defmodule MyApp.Validations.UniqueUsername do
    use Ash.Resource.Validation

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def validate(changeset, _opts, _context) do
      # Validation logic here
      # Return :ok or {:error, message}
    end
  end

  # Usage in resource:
  validate {MyApp.Validations.UniqueUsername, []}
  ```

- Make validations **atomic** when possible to ensure they work correctly with direct database operations by implementing the `atomic/3` callback in custom validation modules.

  ```elixir
  defmodule MyApp.Validations.IsEven do
    # transform and validate opts

    use Ash.Resource.Validation

    @impl true
    def init(opts) do
      if is_atom(opts[:attribute]) do
        {:ok, opts}
      else
        {:error, "attribute must be an atom!"}
      end
    end

    @impl true
    # This is optional, but useful to have in addition to validation
    # so you get early feedback for validations that can otherwise
    # only run in the datalayer
    def validate(changeset, opts, _context) do
      value = Ash.Changeset.get_attribute(changeset, opts[:attribute])

      if is_nil(value) || (is_number(value) && rem(value, 2) == 0) do
        :ok
      else
        {:error, field: opts[:attribute], message: "must be an even number"}
      end
    end

    @impl true
    def atomic(changeset, opts, context) do
      {:atomic,
        # the list of attributes that are involved in the validation
        [opts[:attribute]],
        # the condition that should cause the error
        # here we refer to the new value or the current value
        expr(rem(^atomic_ref(opts[:attribute]), 2) != 0),
        # the error expression
        expr(
          error(^InvalidAttribute, %{
            field: ^opts[:attribute],
            # the value that caused the error
            value: ^atomic_ref(opts[:attribute]),
            # the message to display
            message: ^(context.message || "%{field} must be an even number"),
            vars: %{field: ^opts[:attribute]}
          })
        )
      }
    end
  end
  ```

- **Avoid redundant validations** - Don't add validations that duplicate attribute constraints:
  ```elixir
  # WRONG - redundant validation
  attribute :name, :string do
    allow_nil? false
    constraints min_length: 1
  end

  validate present(:name) do  # Redundant! allow_nil? false already handles this
    message "Name is required"
  end

  validate attribute_does_not_equal(:name, "") do  # Redundant! min_length: 1 already handles this
    message "Name cannot be empty"
  end

  # CORRECT - let attribute constraints handle basic validation
  attribute :name, :string do
    allow_nil? false
    constraints min_length: 1
  end
  ```

## Using Preparations

Preparations modify queries before they're executed. They are used to add filters, sorts, or other query modifications based on the query context.

Common preparation patterns:

```elixir
# Built-in preparations
prepare build(sort: [created_at: :desc])
prepare build(filter: [active: true])

# Conditional preparations with where clauses
prepare build(filter: [visible: true]) do
  where argument_equals(:include_hidden, false)
end

# only_when_valid? - skip preparation if prior validations failed
prepare expensive_preparation() do
  only_when_valid? true
end

# Action-specific vs global preparations
actions do
  read :recent do
    prepare build(sort: [created_at: :desc], limit: 10)
  end
end

preparations do
  prepare build(filter: [deleted: false]), on: [:read, :update]
end
```

## Using Changes

Changes allow you to modify the changeset before it gets processed by an action. Unlike validations, changes can manipulate attribute values, add attributes, or perform other data transformations.

Common change patterns:

```elixir
# Built-in changes with conditions
change set_attribute(:status, "pending")
change relate_actor(:creator) do
  where present(:actor)
end
change atomic_update(:counter, expr(^counter + 1))

# Action-specific vs global changes
actions do
  create :sign_up do
    change set_attribute(:joined_at, expr(now()))  # Only for this action
  end
end

changes do
  change set_attribute(:updated_at, expr(now())), on: :update  # Multiple actions
  change manage_relationship(:items, type: :append), on: [:create, :update]
end
```

- Create **custom change modules** for reusable transformation logic:
  ```elixir
  defmodule MyApp.Changes.SlugifyTitle do
    use Ash.Resource.Change

    def change(changeset, _opts, _context) do
      title = Ash.Changeset.get_attribute(changeset, :title)

      if title do
        slug = title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
        Ash.Changeset.change_attribute(changeset, :slug, slug)
      else
        changeset
      end
    end
  end

  # Usage in resource:
  change {MyApp.Changes.SlugifyTitle, []}
  ```

- Create a **change module with lifecycle hooks** to handle complex multi-step operations:

  ```elixir
  defmodule MyApp.Changes.ProcessOrder do
    use Ash.Resource.Change

    def change(changeset, _opts, context) do
      changeset
      |> Ash.Changeset.before_transaction(fn changeset ->
        # Runs before the transaction starts
        # Use for external API calls, logging, etc.
        MyApp.ExternalService.reserve_inventory(changeset, scope: context)
        changeset
      end)
      |> Ash.Changeset.before_action(fn changeset ->
        # Runs inside the transaction before the main action
        # Use for related database changes in the same transaction
        Ash.Changeset.change_attribute(changeset, :processed_at, DateTime.utc_now())
      end)
      |> Ash.Changeset.after_action(fn changeset, result ->
        # Runs inside the transaction after the main action, only on success
        # Use for related database changes that depend on the result
        MyApp.Inventory.update_stock_levels(result, scope: context)
        {changeset, result}
      end)
      |> Ash.Changeset.after_transaction(fn changeset,
        {:ok, result} ->
          # Runs after the transaction completes (success or failure)
          # Use for notifications, external systems, etc.
          MyApp.Mailer.send_order_confirmation(result, scope: context)
          {changeset, result}

        {:error, error} ->
          # Runs after the transaction completes (success or failure)
          # Use for notifications, external systems, etc.
          MyApp.Mailer.send_order_issue_notice(result, scope: context)
          {:error, error}
      end)
    end
  end

  # Usage in resource:
  change {MyApp.Changes.ProcessOrder, []}
  ```

## Atomic Changes

Atomic changes execute directly in the database as part of the update query, without requiring the record to be loaded first. This provides better performance and correct behavior under concurrent updates.

**Why atomic matters:**
- Avoids race conditions (e.g., incrementing a counter)
- Better performance (no round-trip to load the record)
- Required for bulk operations to work efficiently

**Built-in atomic changes:**
```elixir
# Increment a counter atomically
change atomic_update(:view_count, expr(view_count + 1))

# Set a value using an expression
change set_attribute(:updated_at, expr(now()))
```

**Making custom changes atomic:**
Implement the `atomic/3` callback to support atomic execution:

```elixir
defmodule MyApp.Changes.IncrementVersion do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    # Fallback for non-atomic execution
    current = Ash.Changeset.get_attribute(changeset, :version) || 0
    Ash.Changeset.change_attribute(changeset, :version, current + 1)
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    # Atomic implementation - runs in the database
    {:atomic, %{version: expr(coalesce(version, 0) + 1)}}
  end
end
```

## Using `require_atomic? false`

By default, update and destroy actions require all changes and validations to support atomic execution. If they don't, the action will raise an error.

**IMPORTANT:** When you see `require_atomic? false` on an action, carefully consider whether it is truly necessary. This option should be used sparingly.

**When `require_atomic? false` is needed:**
- The action has `before_action` or `around_action` hooks that need to read or modify the record
- A change reads the current record state (e.g., `Ash.Changeset.get_data/2`) and cannot be rewritten atomically
- Complex validations that cannot be expressed as database expressions

**When `require_atomic? false` is NOT needed:**
- Simple attribute transformations (these can usually be made atomic)
- Setting timestamps or default values (use `expr(now())` instead)
- Incrementing counters (use `atomic_update/2`)
- After-action hooks (these don't prevent atomic execution)
- After-transaction hooks (these don't prevent atomic execution)

```elixir
actions do
  update :update do
    # AVOID unless truly necessary
    require_atomic? false
  end

  update :increment_views do
    # GOOD - fully atomic, no need to disable
    change atomic_update(:view_count, expr(view_count + 1))
  end
end
```

If you find yourself adding `require_atomic? false`, first check if your changes and validations can be rewritten with `atomic/3` callbacks. Only disable atomic requirements when the action genuinely needs to read or manipulate the record in hooks.

## Custom Modules vs. Anonymous Functions

Prefer to put code in its own module and refer to that in changes, preparations, validations etc.

For example, prefer this:

```elixir
defmodule MyApp.MyDomain.MyResource.Changes.SlugifyName do
  use Ash.Resource.Change

  def change(changeset, _, _) do
    Ash.Changeset.before_action(changeset, fn changeset, _ ->
      slug = MyApp.Slug.get()
      Ash.Changeset.force_change_attribute(changeset, :slug, slug)
    end)
  end
end

change MyApp.MyDomain.MyResource.Changes.SlugifyName
```

## Action Types

- **Read**: For retrieving records
- **Create**: For creating records
- **Update**: For changing records
- **Destroy**: For removing records
- **Generic**: For custom operations that don't fit the other types


<!-- ash:actions-end -->
<!-- ash:aggregates-start -->
## ash:aggregates usage
# Aggregates

Aggregates allow you to retrieve summary information over groups of related data, like counts, sums, or averages. Define aggregates in the `aggregates` block of a resource.

Aggregates can work over relationships or directly over unrelated resources:

```elixir
aggregates do
  # Related aggregates - use relationship path
  count :published_post_count, :posts do
    filter expr(published == true)
  end

  sum :total_sales, :orders, :amount

  exists :is_admin, :roles do
    filter expr(name == "admin")
  end

  # Unrelated aggregates - use resource module directly
  count :matching_profiles_count, Profile do
    filter expr(name == parent(name))
  end
  
  sum :total_report_score, Report, :score do
    filter expr(author_name == parent(name))
  end
  
  exists :has_reports, Report do
    filter expr(author_name == parent(name))
  end
end
```

For unrelated aggregates, use `parent/1` to reference fields from the source resource.

## Aggregate Types

- **count**: Counts related items meeting criteria
- **sum**: Sums a field across related items
- **exists**: Returns boolean indicating if matching related items exist (also supports unrelated resources)
- **first**: Gets the first related value matching criteria
- **list**: Lists the related values for a specific field
- **max**: Gets the maximum value of a field
- **min**: Gets the minimum value of a field
- **avg**: Gets the average value of a field

## Using Aggregates

```elixir
# Using code interface options (preferred)
users = MyDomain.list_users!(
  load: [:published_post_count, :total_sales],
  query: [
    filter: [published_post_count: [greater_than: 5]],
    sort: [published_post_count: :desc]
  ]
)

# Manual query building (for complex cases)
User |> Ash.Query.filter(published_post_count > 5) |> Ash.read!()

# Loading on existing records
Ash.load!(users, :published_post_count)
```

### Join Filters

For complex aggregates involving multiple relationships, use join filters:

```elixir
aggregates do
  sum :redeemed_deal_amount, [:redeems, :deal], :amount do
    # Filter on the aggregate as a whole
    filter expr(redeems.redeemed == true)

    # Apply filters to specific relationship steps
    join_filter :redeems, expr(redeemed == true)
    join_filter [:redeems, :deal], expr(active == parent(require_active))
  end
end
```

## Inline Aggregates

Use aggregates inline within expressions:

```elixir
# Related inline aggregates
calculate :grade_percentage, :decimal, expr(
  count(answers, query: [filter: expr(correct == true)]) * 100 /
  count(answers)
)

# Unrelated inline aggregates
calculate :profile_count, :integer, expr(
  count(Profile, filter: expr(name == parent(name)))
)

calculate :stats, :map, expr(%{
  profiles: count(Profile, filter: expr(active == true)),
  reports: count(Report, filter: expr(author_name == parent(name))),
  has_active_profile: exists(Profile, active == true and name == parent(name))
})
```


<!-- ash:aggregates-end -->
<!-- ash:authorization-start -->
## ash:authorization usage
# Authorization

- When performing administrative actions, you can bypass authorization with `authorize?: false`
- To run actions as a particular user, look that user up and pass it as the `actor` option
- Always set the actor on the query/changeset/input, not when calling the action
- Use policies to define authorization rules

```elixir
# Good
Post
|> Ash.Query.for_read(:read, %{}, actor: current_user)
|> Ash.read!()

# BAD, DO NOT DO THIS
Post
|> Ash.Query.for_read(:read, %{})
|> Ash.read!(actor: current_user)
```

## Policies

To use policies, add the `Ash.Policy.Authorizer` to your resource:

```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    authorizers: [Ash.Policy.Authorizer]

  # Rest of resource definition...
end
```

## Policy Basics

Policies determine what actions on a resource are permitted for a given actor. Define policies in the `policies` block:

```elixir
policies do
  # A simple policy that applies to all read actions
  policy action_type(:read) do
    # Authorize if record is public
    authorize_if expr(public == true)

    # Authorize if actor is the owner
    authorize_if relates_to_actor_via(:owner)
  end

  # A policy for create actions
  policy action_type(:create) do
    # Only allow active users to create records
    forbid_unless actor_attribute_equals(:active, true)

    # Ensure the record being created relates to the actor
    authorize_if relating_to_actor(:owner)
  end
end
```

## Policy Evaluation Flow

Policies evaluate from top to bottom with the following logic:

1. All policies that apply to an action must pass for the action to be allowed
2. Within each policy, checks evaluate from top to bottom
3. The first check that produces a decision determines the policy result
4. If no check produces a decision, the policy defaults to forbidden

## IMPORTANT: Policy Check Logic

**the first check that yields a result determines the policy outcome**

```elixir
# WRONG - This is OR logic, not AND logic!
policy action_type(:update) do
  authorize_if actor_attribute_equals(:admin?, true)    # If this passes, policy passes
  authorize_if relates_to_actor_via(:owner)           # Only checked if first fails
end
```

To require BOTH conditions in that example, you would use `forbid_unless` for the first condition:

```elixir
# CORRECT - This requires BOTH conditions
policy action_type(:update) do
  forbid_unless actor_attribute_equals(:admin?, true)  # Must be admin
  authorize_if relates_to_actor_via(:owner)           # AND must be owner
end
```

Alternative patterns for AND logic:
- Use multiple separate policies (each must pass independently)
- Use a single complex expression with `expr(condition1 and condition2)`
- Use `forbid_unless` for required conditions, then `authorize_if` for the final check

## Bypass Policies

Use bypass policies to allow certain actors to bypass other policy restrictions. This should be used almost exclusively for admin bypasses.

```elixir
policies do
  # Bypass policy for admins - if this passes, other policies don't need to pass
  bypass actor_attribute_equals(:admin, true) do
    authorize_if always()
  end

  # Regular policies follow...
  policy action_type(:read) do
    # ...
  end
end
```

## Field Policies

Field policies control access to specific fields (attributes, calculations, aggregates):

```elixir
field_policies do
  # Only supervisors can see the salary field
  field_policy :salary do
    authorize_if actor_attribute_equals(:role, :supervisor)
  end

  # Allow access to all other fields
  field_policy :* do
    authorize_if always()
  end
end
```

## Policy Checks

There are two main types of checks used in policies:

1. **Simple checks** - Return true/false answers (e.g., "is the actor an admin?")
2. **Filter checks** - Return filters to apply to data (e.g., "only show records owned by the actor")

You can use built-in checks or create custom ones:

```elixir
# Built-in checks
authorize_if actor_attribute_equals(:role, :admin)
authorize_if relates_to_actor_via(:owner)
authorize_if expr(public == true)

# Custom check module
authorize_if MyApp.Checks.ActorHasPermission
```

### Custom Policy Checks

Create custom checks by implementing `Ash.Policy.SimpleCheck` or `Ash.Policy.FilterCheck`:

```elixir
# Simple check - returns true/false
defmodule MyApp.Checks.ActorHasRole do
  use Ash.Policy.SimpleCheck

  def match?(%{role: actor_role}, _context, opts) do
    actor_role == (opts[:role] || :admin)
  end
  def match?(_, _, _), do: false
end

# Filter check - returns query filter
defmodule MyApp.Checks.VisibleToUserLevel do
  use Ash.Policy.FilterCheck

  def filter(actor, _authorizer, _opts) do
    expr(visibility_level <= ^actor.user_level)
  end
end

# Usage
policy action_type(:read) do
  authorize_if {MyApp.Checks.ActorHasRole, role: :manager}
  authorize_if MyApp.Checks.VisibleToUserLevel
end
```


<!-- ash:authorization-end -->
<!-- ash:calculations-start -->
## ash:calculations usage
# Calculations

Calculations allow you to define derived values based on a resource's attributes or related data. Define calculations in the `calculations` block of a resource:

```elixir
calculations do
  # Simple expression calculation
  calculate :full_name, :string, expr(first_name <> " " <> last_name)

  # Expression with conditions
  calculate :status_label, :string, expr(
    cond do
      status == :active -> "Active"
      status == :pending -> "Pending Review"
      true -> "Inactive"
    end
  )

  # Using module calculations for more complex logic
  calculate :risk_score, :integer, {MyApp.Calculations.RiskScore, min: 0, max: 100}
end
```

## Expression Calculations

Expression calculations use Ash expressions and can be pushed down to the data layer when possible:

```elixir
calculations do
  # Simple string concatenation
  calculate :full_name, :string, expr(first_name <> " " <> last_name)

  # Math operations
  calculate :total_with_tax, :decimal, expr(amount * (1 + tax_rate))

  # Date manipulation
  calculate :days_since_created, :integer, expr(
    date_diff(^now(), inserted_at, :day)
  )
end
```

## Expressions

In order to use expressions outside of resources, changes, preparations etc. you will need to use `Ash.Expr`.

It provides both `expr/1` and template helpers like `actor/1` and `arg/1`.

For example:

```elixir
import Ash.Expr

Author
|> Ash.Query.aggregate(:count_of_my_favorited_posts, :count, [:posts], query: [
  filter: expr(favorited_by(user_id: ^actor(:id)))
])
```

See the expressions guide for more information on what is available in expresisons and
how to use them.

## Module Calculations

For complex calculations, create a module that implements `Ash.Resource.Calculation`:

```elixir
defmodule MyApp.Calculations.FullName do
  use Ash.Resource.Calculation

  # Validate and transform options
  @impl true
  def init(opts) do
    {:ok, Map.put_new(opts, :separator, " ")}
  end

  # Specify what data needs to be loaded
  @impl true
  def load(_query, _opts, _context) do
    [:first_name, :last_name]
  end

  # Implement the calculation logic
  @impl true
  def calculate(records, opts, _context) do
    Enum.map(records, fn record ->
      [record.first_name, record.last_name]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(opts.separator)
    end)
  end
end

# Usage in a resource
calculations do
  calculate :full_name, :string, {MyApp.Calculations.FullName, separator: ", "}
end
```

## Calculations with Arguments

You can define calculations that accept arguments:

```elixir
calculations do
  calculate :full_name, :string, expr(first_name <> ^arg(:separator) <> last_name) do
    argument :separator, :string do
      allow_nil? false
      default " "
      constraints [allow_empty?: true, trim?: false]
    end
  end
end
```

## Using Calculations

```elixir
# Using code interface options (preferred)
users = MyDomain.list_users!(load: [full_name: [separator: ", "]])

# Filtering and sorting
users = MyDomain.list_users!(
  query: [
    filter: [full_name: [separator: " ", value: "John Doe"]],
    sort: [full_name: {[separator: " "], :asc}]
  ]
)

# Manual query building (for complex cases)
User |> Ash.Query.load(full_name: [separator: ", "]) |> Ash.read!()

# Loading on existing records
Ash.load!(users, :full_name)
```

### Code Interface for Calculations

Define calculation functions on your domain for standalone use:

```elixir
# In your domain
resource User do
  define_calculation :full_name, args: [:first_name, :last_name, {:optional, :separator}]
end

# Then call it directly
MyDomain.full_name("John", "Doe", ", ")  # Returns "John, Doe"
```


<!-- ash:calculations-end -->
<!-- ash:code_interfaces-start -->
## ash:code_interfaces usage
# Code Interfaces

Domains and Resources can define code interfaces. Prefer writing code interfaces instead of regular elixir functions.

Use code interfaces on domains to define the contract for calling into Ash resources. See the [Code interface guide for more](https://hexdocs.pm/ash/code-interfaces.html).

Define code interfaces on the domain, like this:

```elixir
resource ResourceName do
  define :fun_name, action: :action_name
end
```

For more complex interfaces with custom transformations:

```elixir
define :custom_action do
  action :action_name
  args [:arg1, :arg2]

  custom_input :arg1, MyType do
    transform do
      to :target_field
      using &MyModule.transform_function/1
    end
  end
end
```

Prefer using the primary read action for "get" style code interfaces, and using `get_by` when the field you are looking up by is the primary key or has an `identity` on the resource.

```elixir
resource ResourceName do
  define :get_thing, action: :read, get_by: [:id]
end
```

**Avoid direct Ash calls in web modules** - Don't use `Ash.get!/2` and `Ash.load!/2` directly in LiveViews/Controllers, similar to avoiding `Repo.get/2` outside context modules:

You can also pass additional inputs in to code interfaces before the options:

```elixir
resource ResourceName do
  define :create, action: :action_name, args: [:field1]
end
```

```elixir
Domain.create!(field1_value, %{field2: field2_value}, actor: current_user)
```

You should generally prefer using this map of extra inputs over defining optional arguments.

```elixir
# BAD - in LiveView/Controller
group = MyApp.Resource |> Ash.get!(id) |> Ash.load!(rel: [:nested])

# GOOD - use code interface with get_by
resource DashboardGroup do
  define :get_dashboard_group_by_id, action: :read, get_by: [:id]
end

# Then call:
MyApp.Domain.get_dashboard_group_by_id!(id, load: [rel: [:nested]])
```

**Code interface options** - Prefer passing options directly to code interface functions rather than building queries manually:

```elixir
# PREFERRED - Use the query option for filter, sort, limit, etc.
# the query option is passed to `Ash.Query.build/2`
posts = MyApp.Blog.list_posts!(
  query: [
    filter: [status: :published],
    sort: [published_at: :desc],
    limit: 10
  ],
  load: [author: :profile, comments: [:author]]
)

# All query-related options go in the query parameter
users = MyApp.Accounts.list_users!(
  query: [filter: [active: true], sort: [created_at: :desc]],
  load: [:profile]
)

# AVOID - Verbose manual query building
query = MyApp.Post |> Ash.Query.filter(...) |> Ash.Query.load(...)
posts = Ash.read!(query)
```

Supported options: `load:`, `query:` (which accepts `filter:`, `sort:`, `limit:`, `offset:`, etc.), `page:`, `stream?:`

**Using Scopes in LiveViews** - When using `Ash.Scope`, the scope will typically be assigned to `scope` in LiveViews and used like so:

```elixir
# In your LiveView
MyApp.Blog.create_post!("new post", scope: socket.assigns.scope)
```

Inside action hooks and callbacks, use the provided `context` parameter as your scope instead:

```elixir
|> Ash.Changeset.before_transaction(fn changeset, context ->
  MyApp.ExternalService.reserve_inventory(changeset, scope: context)
  changeset
end)
```

## Predicate interfaces (`?`-suffixed names)

When a code interface name ends in `?` (e.g. `define :user_exists?, action: :user_exists?, args: [:email]`), Ash treats it as a **predicate interface** and generates two action functions (same pattern as calculation interfaces):

- `user_exists/…` (with `?` stripped from the name) returns `{:ok, result}` or `{:error, reason}` (from `:action`)
- `user_exists?/…` returns the **unwrapped result** (typically bare `true`/`false`); raises on failure (from `:action!`)
- **No** `user_exists!/…` or `user_exists?!/…`

The action's `run` callback still returns `{:ok, result}` or `{:error, reason}`; the code interface unwraps it for the `?`-suffixed function.

Authorization helpers for predicate interfaces:

- `can_user_exists/…` returns `{:ok, true/false}` or `{:error, reason}`
- `can_user_exists?/…` returns a bare boolean
- **No** `can_user_exists??/…` is generated

Both action functions come from the default `functions:` list (`:action` and `:action!`). Omit `:action` to skip the tuple form; omit `:action!` to skip the predicate form. See the [Code interface guide](https://hexdocs.pm/ash/code-interfaces.html) for examples.

## Authorization Functions

For predicate interfaces (names ending in `?`), see [Predicate interfaces](#predicate-interfaces-suffixed-names) above for naming rules.

For each action defined in a code interface, Ash automatically generates corresponding authorization check functions:

- `can_action_name?(actor, params \\ %{}, opts \\ [])` - Returns `true`/`false` for authorization checks
- `can_action_name(actor, params \\ %{}, opts \\ [])` - Returns `{:ok, true/false}` or `{:error, reason}`

Example usage:
```elixir
# Check if user can create a post
if MyApp.Blog.can_create_post?(current_user) do
  # Show create button
end

# Check if user can update a specific post
if MyApp.Blog.can_update_post?(current_user, post) do
  # Show edit button
end

# Check if user can destroy a specific comment
if MyApp.Blog.can_destroy_comment?(current_user, comment) do
  # Show delete button
end
```

These functions are particularly useful for conditional rendering of UI elements based on user permissions.


<!-- ash:code_interfaces-end -->
<!-- ash:code_structure-start -->
## ash:code_structure usage
# Code Structure & Organization

- Organize code around domains and resources
- Each resource should be focused and well-named
- Create domain-specific actions rather than generic CRUD operations
- Put business logic inside actions rather than in external modules
- Use resources to model your domain entities

<!-- ash:code_structure-end -->
<!-- ash:data_layers-start -->
## ash:data_layers usage
# Data Layers

Data layers determine how resources are stored and retrieved. Examples of data layers:

- **Postgres**: For storing resources in PostgreSQL (via `AshPostgres`)
- **ETS**: For in-memory storage (`Ash.DataLayer.Ets`)
- **Mnesia**: For distributed storage (`Ash.DataLayer.Mnesia`)
- **Embedded**: For resources embedded in other resources (`data_layer: :embedded`) (typically JSON under the hood)
- **Ash.DataLayer.Simple**: For resources that aren't persisted at all. Leave off the data layer, as this is the default.

Specify a data layer when defining a resource:

```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "posts"
    repo MyApp.Repo
  end

  # ... attributes, relationships, etc.
end
```

For embedded resources:

```elixir
defmodule MyApp.Address do
  use Ash.Resource,
    data_layer: :embedded

  attributes do
    attribute :street, :string
    attribute :city, :string
    attribute :state, :string
    attribute :zip, :string
  end
end
```

Each data layer has its own configuration options and capabilities. Refer to the rules & documentation of the specific data layer package for more details.


<!-- ash:data_layers-end -->
<!-- ash:exist_expressions-start -->
## ash:exist_expressions usage
# Exists Expressions

Use `exists/2` to check for the existence of records, either through relationships or unrelated resources:

### Related Exists

```elixir
# Check if user has any admin roles
Ash.Query.filter(User, exists(roles, name == "admin"))

# Check if post has comments with high scores
Ash.Query.filter(Post, exists(comments, score > 50))
```

### Unrelated Exists

```elixir
# Check if any profile exists with the same name
Ash.Query.filter(User, exists(Profile, name == parent(name)))

# Check if user has any reports
Ash.Query.filter(User, exists(Report, author_name == parent(name)))

# Complex existence checks
Ash.Query.filter(User, 
  active == true and 
  exists(Profile, active == true and name == parent(name))
)
```

Unrelated exists expressions automatically apply authorization using the target resource's primary read action. Use `parent/1` to reference fields from the source resource.

<!-- ash:exist_expressions-end -->
<!-- ash:generating_code-start -->
## ash:generating_code usage
# Generating Code

Use `mix ash.gen.*` tasks as a basis for code generation when possible. Check the task docs with `mix help <task>`.
Be sure to use `--yes` to bypass confirmation prompts. Use `--yes --dry-run` to preview the changes.


<!-- ash:generating_code-end -->
<!-- ash:migrations-start -->
## ash:migrations usage
# Migrations and Schema Changes

After creating or modifying Ash code, run `mix ash.codegen <short_name_describing_changes>` to ensure any required additional changes are made (like migrations are generated). The name of the migration should be lower_snake_case. In a longer running dev session it's usually better to use `mix ash.codegen --dev` as you go and at the end run the final codegen with a sensible name describing all the changes made in the session.


<!-- ash:migrations-end -->
<!-- ash:query_filter-start -->
## ash:query_filter usage
# Ash.Query.filter is a macro

**Important**: You must `require Ash.Query` if you want to use `Ash.Query.filter/2`, as it is a macro.

If you see errors like the following:

```
Ash.Query.filter(MyResource, id == ^id)
error: misplaced operator ^id

The pin operator ^ is supported only inside matches or inside custom macros...
```

```
iex(3)> Ash.Query.filter(MyResource, something == true)
error: undefined variable "something"
└─ iex:3
```

You are very likely missing a `require Ash.Query`

## Common Query Operations

- **Filter**: `Ash.Query.filter(query, field == value)`
- **Sort**: `Ash.Query.sort(query, field: :asc)`
- **Load relationships**: `Ash.Query.load(query, [:author, :comments])`
- **Limit**: `Ash.Query.limit(query, 10)`
- **Offset**: `Ash.Query.offset(query, 20)`


<!-- ash:query_filter-end -->
<!-- ash:querying_data-start -->
## ash:querying_data usage
# Querying Data

Use `Ash.Query` to build queries for reading data from your resources. The query module provides a declarative way to filter, sort, and load data.


<!-- ash:querying_data-end -->
<!-- ash:relationships-start -->
## ash:relationships usage
# Relationships

Relationships describe connections between resources and are a core component of Ash. Define relationships in the `relationships` block of a resource.

## Best Practices for Relationships

- Be descriptive with relationship names (e.g., use `:authored_posts` instead of just `:posts`)
- Configure foreign key constraints in your data layer if they have them (see `references` in AshPostgres)
- Always choose the appropriate relationship type based on your domain model

### Relationship Types

- For Polymorphic relationships, you can model them using `Ash.Type.Union`; see the “Polymorphic Relationships” guide for more information.

```elixir
relationships do
  # belongs_to - adds foreign key to source resource
  belongs_to :owner, MyApp.User do
    allow_nil? false
    attribute_type :integer  # defaults to :uuid
  end

  # has_one - foreign key on destination resource
  has_one :profile, MyApp.Profile

  # has_many - foreign key on destination resource, returns list
  has_many :posts, MyApp.Post do
    filter expr(published == true)
    sort published_at: :desc
  end

  # many_to_many - requires join resource
  many_to_many :tags, MyApp.Tag do
    through MyApp.PostTag
    source_attribute_on_join_resource :post_id
    destination_attribute_on_join_resource :tag_id
  end
end
```

The join resource must be defined separately:

```elixir
defmodule MyApp.PostTag do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer

  attributes do
    uuid_primary_key :id
    # Add additional attributes if you need metadata on the relationship
    attribute :added_at, :utc_datetime_usec do
      default &DateTime.utc_now/0
    end
  end

  relationships do
    belongs_to :post, MyApp.Post, primary_key?: true, allow_nil?: false
    belongs_to :tag, MyApp.Tag, primary_key?: true, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
```

## Loading Relationships

```elixir
# Using code interface options (preferred)
post = MyDomain.get_post!(id, load: [:author, comments: [:author]])

# Complex loading with filters
posts = MyDomain.list_posts!(
  query: [load: [comments: [filter: [is_approved: true], limit: 5]]]
)

# Manual query building (for complex cases)
MyApp.Post
|> Ash.Query.load(comments: MyApp.Comment |> Ash.Query.filter(is_approved == true))
|> Ash.read!()

# Loading on existing records
Ash.load!(post, :author)
```

Prefer to use the `strict?` option when loading to only load necessary fields on related data.

```elixir
MyApp.Post
|> Ash.Query.load([comments: [:title]], strict?: true)
```

## Managing Relationships

There are two primary ways to manage relationships in Ash:

### 1. Using `change manage_relationship/2-3` in Actions
Use this when input comes from action arguments:

```elixir
actions do
  update :update do
    # Define argument for the related data
    argument :comments, {:array, :map} do
      allow_nil? false
    end

    argument :new_tags, {:array, :map}

    # Link argument to relationship management
    change manage_relationship(:comments, type: :append)

    # For different argument and relationship names
    change manage_relationship(:new_tags, :tags, type: :append)
  end
end
```

### 2. Using `Ash.Changeset.manage_relationship/3-4` in Custom Changes
Use this when building values programmatically:

```elixir
defmodule MyApp.Changes.AssignTeamMembers do
  use Ash.Resource.Change

  def change(changeset, _opts, context) do
    members = determine_team_members(changeset, context.actor)

    Ash.Changeset.manage_relationship(
      changeset,
      :members,
      members,
      type: :append_and_remove
    )
  end
end
```

### Quick Reference - Management Types
- `:append` - Add new related records, ignore existing
- `:append_and_remove` - Add new related records, remove missing
- `:remove` - Remove specified related records
- `:direct_control` - Full CRUD control (create/update/destroy)
- `:create` - Only create new records

### Quick Reference - Common Options
- `on_lookup: :relate` - Look up and relate existing records
- `on_no_match: :create` - Create if no match found
- `on_match: :update` - Update existing matches
- `on_missing: :destroy` - Delete records not in input
- `value_is_key: :name` - Use field as key for simple values

For comprehensive documentation, see the [Managing Relationships](https://hexdocs.pm/ash/relationships.html#managing-relationships) section.

### Examples

Creating a post with tags:
```elixir
MyDomain.create_post!(%{
  title: "New Post",
  body: "Content here...",
  tags: [%{name: "elixir"}, %{name: "ash"}]  # Creates new tags
})

# Updating a post to replace its tags
MyDomain.update_post!(post, %{
  tags: [tag1.id, tag2.id]  # Replaces tags with existing ones by ID
})
```


<!-- ash:relationships-end -->
<!-- ash:testing-start -->
## ash:testing usage
# Testing

When testing resources:
- Test your domain actions through the code interface
- Use test utilities in `Ash.Test`
- Test authorization policies work as expected using `Ash.can?`
- Use `authorize?: false` in tests where authorization is not the focus
- Write generators using `Ash.Generator`
- Prefer to use raising versions of functions whenever possible, as opposed to pattern matching

## Preventing Deadlocks in Concurrent Tests

When running tests concurrently, using fixed values for identity attributes can cause deadlock errors. Multiple tests attempting to create records with the same unique values will conflict.

### Use Globally Unique Values

Always use globally unique values for identity attributes in tests:

```elixir
# BAD - Can cause deadlocks in concurrent tests
%{email: "test@example.com", username: "testuser"}

# GOOD - Use globally unique values
%{
  email: "test-#{System.unique_integer([:positive])}@example.com",
  username: "user_#{System.unique_integer([:positive])}",
  slug: "post-#{System.unique_integer([:positive])}"
}
```

### Creating Reusable Test Generators

For better organization, create a generator module:

```elixir
defmodule MyApp.TestGenerators do
  use Ash.Generator

  def user(opts \\ []) do
    changeset_generator(
      User,
      :create,
      defaults: [
        email: "user-#{System.unique_integer([:positive])}@example.com",
        username: "user_#{System.unique_integer([:positive])}"
      ],
      overrides: opts
    )
  end
end

# In your tests
test "concurrent user creation" do
  users = MyApp.TestGenerators.generate_many(user(), 10)
  # Each user has unique identity attributes
end
```

This applies to ANY field used in identity constraints, not just primary keys. Using globally unique values prevents frustrating intermittent test failures in CI environments.

<!-- ash:testing-end -->
<!-- ash_oban-start -->
## ash_oban usage
_The extension for integrating Ash resources with Oban._

# Rules for working with AshOban

## Understanding AshOban

AshOban is a package that integrates the Ash Framework with Oban, a robust job processing system for Elixir. It enables you to define triggers that can execute background jobs based on specific conditions in your Ash resources, as well as schedule periodic actions. AshOban is particularly useful for handling asynchronous tasks, background processing, and scheduled operations in your Ash application.

<!-- ash_oban-end -->
<!-- ash_oban:best_practices-start -->
## ash_oban:best_practices usage
# Best Practices

1. **Always define module names** - Use explicit `worker_module_name` and `scheduler_module_name` to prevent issues when refactoring.

2. **Use meaningful trigger names** - Choose clear, descriptive names for your triggers that reflect their purpose.

3. **Handle errors gracefully** - Use the `on_error` option to define how to handle records that fail processing repeatedly.

4. **Use appropriate queues** - Organize your jobs into different queues based on priority and resource requirements.

5. **Optimize read actions** - Ensure that read actions used in triggers support keyset pagination for efficient processing.

6. **Design for idempotency** - Jobs should be designed to be safely retried without causing data inconsistencies.

<!-- ash_oban:best_practices-end -->
<!-- ash_oban:debugging_and_error_handling-start -->
## ash_oban:debugging_and_error_handling usage
# Debugging and Error Handling

AshOban provides options for debugging and handling errors:

```elixir
trigger :process do
  action :process
  # Enable detailed debug logging for this trigger
  debug? true

  # Configure error handling
  log_errors? true
  log_final_error? true

  # Define an action to call after the last attempt has failed
  on_error :mark_failed
end
```

You can also enable global debug logging:

```elixir
config :ash_oban, :debug_all_triggers?, true
```

## Snoozing and Cancelling Jobs

From within any action run by a trigger or scheduled action, you can snooze or cancel the Oban job using special error types. These work from both the main action and the `on_error` action.

**Snooze** — re-schedule the job after a delay without consuming a retry attempt:

```elixir
# Via add_error (idiomatic for change functions):
Ash.Changeset.add_error(changeset, AshOban.Errors.SnoozeJob.exception(snooze_for: 60))

# Via raise:
raise AshOban.Errors.SnoozeJob, snooze_for: 60
```

**Cancel** — stop all retries and mark the job as cancelled:

```elixir
# Via add_error:
Ash.Changeset.add_error(changeset, AshOban.Errors.CancelJob.exception(reason: :permanently_invalid))

# Via raise:
raise AshOban.Errors.CancelJob, reason: :permanently_invalid
```
<!-- ash_oban:debugging_and_error_handling-end -->
<!-- ash_oban:defining_triggers-start -->
## ash_oban:defining_triggers usage
# Defining Triggers

Triggers are the primary way to define background jobs in AshOban. They can be configured to run when certain conditions are met on your resources. They work
by running a scheduler job on the given cron job.

## Basic Trigger

```elixir
oban do
  triggers do
    trigger :process do
      action :process
      scheduler_cron "*/5 * * * *"
      where expr(processed != true)
      worker_read_action :read
      worker_module_name MyApp.Workers.Process
      scheduler_module_name MyApp.Schedulers.Process
    end
  end
end
```

## Trigger Configuration Options

- `action` - The action to be triggered (required)
- `where` - The filter expression to determine if something should be triggered
- `worker_read_action` - The read action to use when fetching individual records
- `read_action` - The read action to use when querying records (must support keyset pagination)
- `worker_module_name` - The module name for the generated worker (important for job stability)
- `scheduler_module_name` - The module name for the generated scheduler
- `max_attempts` - How many times to attempt the job (default: 1)
- `queue` - The queue to place the worker job in (defaults to trigger name)
- `trigger_once?` - Ensures that jobs that complete quickly aren't rescheduled (default: false)
<!-- ash_oban:defining_triggers-end -->
<!-- ash_oban:multi_tenancy_support-start -->
## ash_oban:multi_tenancy_support usage
# Multi-tenancy Support

AshOban supports multi-tenancy in your Ash application:

```elixir
oban do
  # Global tenant configuration
  list_tenants [1, 2, 3]  # or a function that returns tenants

  triggers do
    trigger :process do
      # Override tenants for a specific trigger
      list_tenants fn -> [2] end
      action :process
    end
  end
end
```
<!-- ash_oban:multi_tenancy_support-end -->
<!-- ash_oban:scheduled_actions-start -->
## ash_oban:scheduled_actions usage
# Scheduled Actions

Scheduled actions allow you to run periodic tasks according to a cron schedule:

```elixir
oban do
  scheduled_actions do
    schedule :daily_report, "0 8 * * *" do
      action :generate_report
      worker_module_name MyApp.Workers.DailyReport
    end
  end
end
```

## Scheduled Action Configuration Options

- `cron` - The schedule in crontab notation
- `action` - The generic or create action to call when the schedule is triggered
- `action_input` - Inputs to supply to the action when it is called
- `worker_module_name` - The module name for the generated worker
- `queue` - The queue to place the job in
- `max_attempts` - How many times to attempt the job (default: 1)
<!-- ash_oban:scheduled_actions-end -->
<!-- ash_oban:setting_up_ash_oban-start -->
## ash_oban:setting_up_ash_oban usage
# Setting Up AshOban

To use AshOban with an Ash resource, add AshOban to the extensions list:

```elixir
use Ash.Resource,
  extensions: [AshOban]
```
<!-- ash_oban:setting_up_ash_oban-end -->
<!-- ash_oban:triggering_jobs_programmatically-start -->
## ash_oban:triggering_jobs_programmatically usage
# Triggering Jobs Programmatically

You can trigger jobs programmatically using `run_oban_trigger` in your actions:

```elixir
update :process_item do
  accept [:item_id]
  change set_attribute(:processing, true)
  change run_oban_trigger(:process_data)
end
```

Or directly using the AshOban API:

```elixir
# Run a trigger for a specific record
AshOban.run_trigger(record, :process_data)

# Run a trigger for multiple records
AshOban.run_triggers(records, :process_data)

# Schedule a trigger or scheduled action
AshOban.schedule(MyApp.Resource, :process_data, actor: current_user)
```
<!-- ash_oban:triggering_jobs_programmatically-end -->
<!-- ash_oban:working_with_actors-start -->
## ash_oban:working_with_actors usage
# Working with Actors

AshOban can persist the actor that triggered a job, making it available when the job runs:

## Setting up Actor Persistence

```elixir
# Define an actor persister module
defmodule MyApp.ObanActorPersister do
  @behaviour AshOban.PersistActor

  @impl true
  def store(actor) do
    # Convert actor to a format that can be stored in JSON
    Jason.encode!(actor)
  end

  @impl true
  def lookup(actor_json) do
    # Convert the stored JSON back to an actor
    case Jason.decode(actor_json) do
      {:ok, data} -> {:ok, MyApp.Accounts.get_user!(data["id"])}
      error -> error
    end
  end
end

# Configure it
config :ash_oban, :actor_persister, MyApp.ObanActorPersister
```

## Using Actor in Triggers

```elixir
# Specify actor_persister for a specific trigger
trigger :process do
  action :process
  actor_persister MyApp.ObanActorPersister
end

# Pass the actor when triggering a job
AshOban.run_trigger(record, :process, actor: current_user)
```
<!-- ash_oban:working_with_actors-end -->
<!-- ash_postgres-start -->
## ash_postgres usage
_The PostgreSQL data layer for Ash Framework_

# Rules for working with AshPostgres

## Understanding AshPostgres

AshPostgres is the PostgreSQL data layer for Ash Framework. It's the most fully-featured Ash data layer and should be your default choice unless you have specific requirements for another data layer. Any PostgreSQL version higher than 13 is fully supported.

Remember that using AshPostgres provides a full-featured PostgreSQL data layer for your Ash application, giving you both the structure and declarative approach of Ash along with the power and flexibility of PostgreSQL.

<!-- ash_postgres-end -->
<!-- ash_postgres:advanced_features-start -->
## ash_postgres:advanced_features usage
# Advanced Features

## Manual Relationships

For complex relationships that can't be expressed with standard relationship types:

```elixir
defmodule MyApp.Post.Relationships.HighlyRatedComments do
  use Ash.Resource.ManualRelationship
  use AshPostgres.ManualRelationship

  def load(posts, _opts, context) do
    post_ids = Enum.map(posts, & &1.id)

    {:ok,
     MyApp.Comment
     |> Ash.Query.filter(post_id in ^post_ids)
     |> Ash.Query.filter(rating > 4)
     |> MyApp.read!()
     |> Enum.group_by(& &1.post_id)}
  end

  def ash_postgres_join(query, _opts, current_binding, as_binding, :inner, destination_query) do
    {:ok,
     Ecto.Query.from(_ in query,
       join: dest in ^destination_query,
       as: ^as_binding,
       on: dest.post_id == as(^current_binding).id,
       on: dest.rating > 4
     )}
  end

  # Other required callbacks...
end

# In your resource:
relationships do
  has_many :highly_rated_comments, MyApp.Comment do
    manual MyApp.Post.Relationships.HighlyRatedComments
  end
end
```

## Using Multiple Repos (Read Replicas)

Configure different repos for reads vs mutations:

```elixir
postgres do
  repo fn resource, type ->
    case type do
      :read -> MyApp.ReadReplicaRepo
      :mutate -> MyApp.WriteRepo
    end
  end
end
```
<!-- ash_postgres:advanced_features-end -->
<!-- ash_postgres:best_practices-start -->
## ash_postgres:best_practices usage
# Best Practices

1. **Organize migrations**: Run `mix ash.codegen` after each meaningful set of resource changes with a descriptive name:
   ```bash
   mix ash.codegen --name add_user_roles
   mix ash.codegen --name implement_post_tagging
   ```

2. **Use check constraints for domain invariants**: Enforce data integrity at the database level:
   ```elixir
   check_constraints do
     check_constraint :valid_status, check: "status IN ('pending', 'active', 'completed')"
     check_constraint :positive_balance, check: "balance >= 0"
   end
   ```

3. **Use custom statements for schema-only changes**: If you need to add database objects not directly tied to resources:
   ```elixir
   custom_statements do
     statement "CREATE EXTENSION IF NOT EXISTS \"pgcrypto\""
     statement "CREATE INDEX users_search_idx ON users USING gin(search_vector)"
   end
   ```
<!-- ash_postgres:best_practices-end -->
<!-- ash_postgres:check_constraints-start -->
## ash_postgres:check_constraints usage
# Check Constraints

Define database check constraints:

```elixir
postgres do
  check_constraints do
    check_constraint :positive_amount,
      check: "amount > 0",
      name: "positive_amount_check",
      message: "Amount must be positive"

    check_constraint :status_valid,
      check: "status IN ('pending', 'active', 'completed')"
  end
end
```
<!-- ash_postgres:check_constraints-end -->
<!-- ash_postgres:configuration-start -->
## ash_postgres:configuration usage
# Basic Configuration

To use AshPostgres, add the data layer to your resource:

```elixir
defmodule MyApp.Tweet do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer

  attributes do
    integer_primary_key :id
    attribute :text, :string
  end

  relationships do
    belongs_to :author, MyApp.User
  end

  postgres do
    table "tweets"
    repo MyApp.Repo
  end
end
```

# PostgreSQL Configuration

## Table & Schema Configuration

```elixir
postgres do
  # Required: Define the table name for this resource
  table "users"

  # Optional: Define the PostgreSQL schema
  schema "public"

  # Required: Define the Ecto repo to use
  repo MyApp.Repo

  # Optional: Control whether migrations are generated for this resource
  migrate? true
end
```

<!-- ash_postgres:configuration-end -->
<!-- ash_postgres:custom_indexes-start -->
## ash_postgres:custom_indexes usage
# Custom Indexes

Define custom indexes beyond those automatically created for identities and relationships:

```elixir
postgres do
  custom_indexes do
    index [:first_name, :last_name]

    index :email,
      unique: true,
      name: "users_email_index",
      where: "email IS NOT NULL",
      using: :gin

    index [:status, :created_at],
      concurrently: true,
      include: [:user_id]
  end
end
```
<!-- ash_postgres:custom_indexes-end -->
<!-- ash_postgres:custom_sql_statements-start -->
## ash_postgres:custom_sql_statements usage
# Custom SQL Statements

Include custom SQL in migrations:

```elixir
postgres do
  custom_statements do
    statement "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\""

    statement """
    CREATE TRIGGER update_updated_at
    BEFORE UPDATE ON posts
    FOR EACH ROW
    EXECUTE FUNCTION trigger_set_timestamp();
    """

    statement "DROP INDEX IF EXISTS posts_title_index",
      on_destroy: true # Only run when resource is destroyed/dropped
  end
end
```
<!-- ash_postgres:custom_sql_statements-end -->
<!-- ash_postgres:foreign_keys-start -->
## ash_postgres:foreign_keys usage
# Foreign Key References

Use the `references` section to configure foreign key behavior:

```elixir
postgres do
  table "comments"
  repo MyApp.Repo

  references do
    # Simple reference with defaults
    reference :post

    # Fully configured reference
    reference :user,
      on_delete: :delete,      # What happens when referenced row is deleted
      on_update: :update,      # What happens when referenced row is updated
      name: "comments_to_users_fkey", # Custom constraint name
      deferrable: true,        # Make constraint deferrable
      initially_deferred: false # Defer constraint check to end of transaction
  end
end
```

## Foreign Key Actions

For `on_delete` and `on_update` options:

- `:nothing` or `:restrict` - Prevent the change to the referenced row
- `:delete` - Delete the row when the referenced row is deleted (for `on_delete` only)
- `:update` - Update the row according to changes in the referenced row (for `on_update` only)
- `:nilify` - Set all foreign key columns to NULL
- `{:nilify, columns}` - Set specific columns to NULL (Postgres 15.0+ only)

> **Warning**: These operations happen directly at the database level. No resource logic, authorization rules, validations, or notifications are triggered.
<!-- ash_postgres:foreign_keys-end -->
<!-- ash_postgres:migrations-start -->
## ash_postgres:migrations usage
# Migrations and Codegen

## Development Migration Workflow (Recommended)

For development iterations, use the dev workflow to avoid naming migrations prematurely:

1. Make resource changes
2. Run `mix ash.codegen --dev` to generate and run dev migrations
3. Review the migrations and run `mix ash.migrate` to run them
4. Continue making changes and running `mix ash.codegen --dev` as needed
5. When your feature is complete, run `mix ash.codegen add_feature_name` to generate final named migrations (this will rollback dev migrations and squash them)
3. Review the migrations and run `mix ash.migrate` to run them

## Traditional Migration Generation

For single-step changes or when you know the final feature name:

1. Run `mix ash.codegen add_feature_name` to generate migrations
2. Review the generated migrations in `priv/repo/migrations`
3. Run `mix ash.migrate` to apply the migrations

> **Tip**: The dev workflow (`--dev` flag) is preferred during development as it allows you to iterate without thinking of migration names and provides better development ergonomics.

> **Warning**: Always review migrations before applying them to ensure they are correct and safe.
<!-- ash_postgres:migrations-end -->
<!-- ash_postgres:multitenancy-start -->
## ash_postgres:multitenancy usage
# Multitenancy

AshPostgres supports schema-based multitenancy:

```elixir
defmodule MyApp.Tenant do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer

  # Resource definition...

  postgres do
    table "tenants"
    repo MyApp.Repo

    # Automatically create/manage tenant schemas
    manage_tenant do
      template ["tenant_", :id]
    end
  end
end
```

## Setting Up Multitenancy

1. Configure your repo to support multitenancy:

```elixir
defmodule MyApp.Repo do
  use AshPostgres.Repo, otp_app: :my_app

  # Return all tenant schemas for migrations
  def all_tenants do
    import Ecto.Query, only: [from: 2]
    all(from(t in "tenants", select: fragment("? || ?", "tenant_", t.id)))
  end
end
```

2. Mark resources that should be multi-tenant:

```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer

  multitenancy do
    strategy :context
    attribute :tenant
  end

  # Resource definition...
end
```

3. When tenant migrations are generated, they'll be in `priv/repo/tenant_migrations`

4. Run tenant migrations in addition to regular migrations:

```bash
# Run regular migrations
mix ash.migrate

# Run tenant migrations
mix ash_postgres.migrate --tenants
```
<!-- ash_postgres:multitenancy-end -->
<!-- igniter-start -->
## igniter usage
_A code generation and project patching framework_

# Rules for working with Igniter

## Understanding Igniter

Igniter is a code generation and project patching framework that enables semantic manipulation of Elixir codebases. It provides tools for creating intelligent generators that can both create new files and modify existing ones safely. Igniter works with AST (Abstract Syntax Trees) through Sourceror.Zipper to make precise, context-aware changes to your code.

## Available Modules

### Project-Level Modules (`Igniter.Project.*`)

- **`Igniter.Project.Application`** - Working with Application modules and application configuration
- **`Igniter.Project.Config`** - Modifying Elixir config files (config.exs, runtime.exs, etc.)
- **`Igniter.Project.Deps`** - Managing dependencies declared in mix.exs
- **`Igniter.Project.Formatter`** - Interacting with .formatter.exs files
- **`Igniter.Project.IgniterConfig`** - Managing .igniter.exs configuration files
- **`Igniter.Project.MixProject`** - Updating project configuration in mix.exs
- **`Igniter.Project.Module`** - Creating and managing modules with proper file placement
- **`Igniter.Project.TaskAliases`** - Managing task aliases in mix.exs
- **`Igniter.Project.Test`** - Working with test and test support files

### Code-Level Modules (`Igniter.Code.*`)

- **`Igniter.Code.Common`** - General purpose utilities for working with Sourceror.Zipper
- **`Igniter.Code.Function`** - Working with function definitions and calls
- **`Igniter.Code.Keyword`** - Manipulating keyword lists
- **`Igniter.Code.List`** - Working with lists in AST
- **`Igniter.Code.Map`** - Manipulating maps
- **`Igniter.Code.Module`** - Working with module definitions and usage
- **`Igniter.Code.String`** - Utilities for string literals
- **`Igniter.Code.Tuple`** - Working with tuples

<!-- igniter-end -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
