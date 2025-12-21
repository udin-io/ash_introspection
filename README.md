<!--
SPDX-FileCopyrightText: 2025 ash_introspection contributors

SPDX-License-Identifier: MIT
-->

# AshIntrospection

![Elixir CI](https://github.com/ash-project/ash_introspection/workflows/CI/badge.svg)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Hex version badge](https://img.shields.io/hexpm/v/ash_introspection.svg)](https://hex.pm/packages/ash_introspection)
[![Hexdocs badge](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/ash_introspection)

> **Alpha Software**: This library is under active development. APIs may change without notice between versions. Use in production at your own risk.

**Shared core library for Ash interoperability with multiple languages**

AshIntrospection provides the foundational modules used by language-specific generators like [AshTypescript](https://github.com/ash-project/ash_typescript) and AshKotlinMultiplatform. It enables seamless RPC communication between Elixir/Ash backends and clients in TypeScript, Kotlin, Swift, and other languages.

## Features

- **Unified Type Introspection** - Consistent type classification and analysis across all Ash types
- **Language-Agnostic RPC Pipeline** - Execute Ash actions with field selection, filtering, and pagination
- **Bidirectional Field Name Mapping** - Convert between snake_case (Elixir) and camelCase (clients)
- **Type-Driven Value Formatting** - Format values based on their Ash types for input/output
- **Comprehensive Error Handling** - Standardized error responses with field paths and interpolation
- **Code Generation Utilities** - Type discovery, action introspection, and validation error classification

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:ash_introspection, "~> 0.2"}
  ]
end
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│           Language-Specific Generators                      │
│        (AshTypescript, AshKotlinMultiplatform)             │
└────────────────────┬────────────────────────────────────────┘
                     │ delegates to
                     ▼
┌─────────────────────────────────────────────────────────────┐
│         AshIntrospection (Shared Core Library)             │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Type System                                        │   │
│  │  • Introspection - Type classification & unwrap     │   │
│  │  • ResourceFields - Field type lookup               │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  RPC Pipeline (4-Stage)                             │   │
│  │  • Stage 1: Parse request (language-specific)       │   │
│  │  • Stage 2: Execute Ash action                      │   │
│  │  • Stage 3: Process result (extract fields)         │   │
│  │  • Stage 4: Format output (convert field names)     │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Code Generation                                    │   │
│  │  • TypeDiscovery - Resource & type scanning         │   │
│  │  • ActionIntrospection - Action analysis            │   │
│  │  • ValidationErrorTypes - Error type classification │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                    Ash Framework                            │
│          (Resources, Types, Queries, Changesets)           │
└─────────────────────────────────────────────────────────────┘
```

## Module Reference

### Type System

| Module | Description |
|--------|-------------|
| `AshIntrospection.TypeSystem.Introspection` | Core type classification, NewType unwrapping, union extraction |
| `AshIntrospection.TypeSystem.ResourceFields` | Unified field lookup for attributes, calculations, relationships |

### RPC Runtime

| Module | Description |
|--------|-------------|
| `AshIntrospection.Rpc.Request` | Request data structure for the RPC pipeline |
| `AshIntrospection.Rpc.Pipeline` | Language-agnostic 4-stage action execution pipeline |
| `AshIntrospection.Rpc.ValueFormatter` | Bidirectional type-driven value formatting |
| `AshIntrospection.Rpc.ResultProcessor` | Field extraction from action results |
| `AshIntrospection.Rpc.FieldExtractor` | Unified extraction for maps, structs, keywords, tuples |

### Field Processing

| Module | Description |
|--------|-------------|
| `AshIntrospection.Rpc.FieldProcessing.Atomizer` | Convert client field names to atoms |
| `AshIntrospection.Rpc.FieldProcessing.FieldSelector` | Type-driven recursive field selection |
| `AshIntrospection.Rpc.FieldProcessing.Validation` | Duplicate detection and field validation |

### Error Handling

| Module | Description |
|--------|-------------|
| `AshIntrospection.Rpc.Error` | Protocol for extracting exception information |
| `AshIntrospection.Rpc.ErrorBuilder` | Comprehensive error message generation |
| `AshIntrospection.Rpc.Errors` | Central error processing pipeline |
| `AshIntrospection.Rpc.DefaultErrorHandler` | Pass-through error handler |

### Code Generation

| Module | Description |
|--------|-------------|
| `AshIntrospection.Codegen.TypeDiscovery` | Recursive resource and type scanning |
| `AshIntrospection.Codegen.ActionIntrospection` | Action pagination, input, and return type analysis |
| `AshIntrospection.Codegen.ValidationErrorTypes` | Validation error type classification |

### Formatting Utilities

| Module | Description |
|--------|-------------|
| `AshIntrospection.FieldFormatter` | Field name formatting (camelCase, PascalCase, snake_case) |
| `AshIntrospection.Helpers` | Low-level case conversion utilities |

## RPC Pipeline

The RPC pipeline executes Ash actions in four stages:

### Stage 1: Parse Request (Language-Specific)

Implemented by each language generator. Parses and validates client input, builds the `Request` struct.

### Stage 2: Execute Ash Action

```elixir
{:ok, result} = AshIntrospection.Rpc.Pipeline.execute_ash_action(request, config)
```

Executes read, create, update, destroy, or generic actions with proper authorization.

### Stage 3: Process Result

```elixir
{:ok, filtered} = AshIntrospection.Rpc.Pipeline.process_result(result, request, config)
```

Applies field selection using the pre-computed extraction template.

### Stage 4: Format Output

```elixir
formatted = AshIntrospection.Rpc.Pipeline.format_output_with_request(filtered, request, config)
```

Converts field names and structures for client consumption.

### Pipeline Configuration

```elixir
config = %{
  input_field_formatter: :camel_case,      # Parse camelCase from client
  output_field_formatter: :camel_case,     # Output camelCase to client
  field_names_callback: :interop_field_names,
  not_found_error?: true,                  # Return error for missing records
  get_original_field_name: fn resource, client_key ->
    # Custom field name resolution
  end,
  format_field_for_client: fn field_name, resource, formatter ->
    # Custom field name formatting
  end
}
```

## Field Name Mapping

### The `interop_field_names/0` Callback

Types can define field name mappings for client compatibility:

```elixir
defmodule MyApp.TaskStats do
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        is_active?: [type: :boolean],
        task_count: [type: :integer]
      ]
    ]

  # Map invalid identifiers to valid client names
  def interop_field_names do
    [
      is_active?: "isActive",
      task_count: "taskCount"
    ]
  end
end
```

### The `interop_type_name/0` Callback

Custom types can specify their representation in generated code:

```elixir
defmodule MyApp.Money do
  use Ash.Type

  def interop_type_name, do: "Money"

  # ... type implementation
end
```

## Type-Driven Dispatch

Many modules use a unified dispatch pattern based on `{type, constraints}` tuples:

```elixir
# ValueFormatter dispatches based on type
ValueFormatter.format(value, Ash.Type.Map, [fields: [...]], :output, config)

# ResultProcessor extracts fields based on type
ResultProcessor.process(result, template, resource, config)

# FieldSelector validates based on type
FieldSelector.process(fields, resource, action, config)
```

This makes types self-describing and enables consistent handling across all modules.

## Code Generation Utilities

### Type Discovery

Scan resources to find all referenced types:

```elixir
alias AshIntrospection.Codegen.TypeDiscovery

# Find all resources referenced by RPC resources
{:ok, resources} = TypeDiscovery.scan_rpc_resources(rpc_resources, domain)

# Find embedded resources
embedded = TypeDiscovery.find_embedded_resources(resources, domain)

# Find types with field constraints
typed_structs = TypeDiscovery.find_field_constrained_types(resources, domain)
```

### Action Introspection

Analyze action characteristics:

```elixir
alias AshIntrospection.Codegen.ActionIntrospection

# Pagination support
ActionIntrospection.action_supports_pagination?(action)
ActionIntrospection.action_supports_offset_pagination?(action)
ActionIntrospection.action_supports_keyset_pagination?(action)

# Input requirements
ActionIntrospection.action_input_type(resource, action)  # :required | :optional | :none
ActionIntrospection.get_required_inputs(resource, action)
ActionIntrospection.get_optional_inputs(resource, action)

# Return type analysis for generic actions
ActionIntrospection.action_returns_field_selectable_type?(action)
# => {:ok, :resource, MyApp.User}
# => {:ok, :array_of_resource, MyApp.User}
# => {:ok, :typed_map, [field: [type: :string]]}
# => {:error, :not_field_selectable_type}
```

### Validation Error Types

Classify validation error types for code generation:

```elixir
alias AshIntrospection.Codegen.ValidationErrorTypes

# Classify a type's error structure
{:ok, classification} = ValidationErrorTypes.classify_error_type(type, constraints)
# => {:primitive_errors, nil}
# => {:resource_errors, MyApp.Address}
# => {:typed_container_errors, [{:name, {:primitive_errors, nil}}, ...]}
# => {:array_errors, {:resource_errors, MyApp.Item}}

# Classify action input errors
classifications = ValidationErrorTypes.classify_action_input_errors(resource, action)
# => [{:title, {:primitive_errors, nil}, %Ash.Resource.Attribute{...}}, ...]
```

---

# Integrating a New Language

This section guides you through creating a new language generator (e.g., AshKotlin, AshSwift, AshGo) using AshIntrospection.

## Overview

A language generator typically provides:

1. **Code Generation** - Generate types, interfaces, and RPC client functions
2. **RPC Runtime** - Execute Ash actions from client requests
3. **DSL Extensions** - Configure which actions to expose

## Step 1: Project Setup

Create a new Elixir package:

```elixir
# mix.exs
defmodule AshKotlin.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_kotlin,
      version: "0.1.0",
      deps: deps()
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:ash_introspection, "~> 0.2"},
      {:spark, "~> 2.0"}
    ]
  end
end
```

## Step 2: Type Mapping

Create a module to map Ash types to your target language:

```elixir
defmodule AshKotlin.Codegen.TypeMapper do
  alias AshIntrospection.TypeSystem.Introspection

  @primitive_types %{
    Ash.Type.String => "String",
    Ash.Type.Integer => "Int",
    Ash.Type.Float => "Double",
    Ash.Type.Boolean => "Boolean",
    Ash.Type.UUID => "String",
    Ash.Type.Date => "LocalDate",
    Ash.Type.DateTime => "Instant"
  }

  def map_type(type, constraints \\ []) do
    # Unwrap NewTypes first
    {unwrapped, full_constraints} = Introspection.unwrap_new_type(type, constraints)

    cond do
      # Arrays
      match?({:array, _}, type) ->
        {:array, inner} = type
        inner_type = map_type(inner, Keyword.get(constraints, :items, []))
        "List<#{inner_type}>"

      # Primitives
      Map.has_key?(@primitive_types, unwrapped) ->
        Map.get(@primitive_types, unwrapped)

      # Embedded resources
      Introspection.is_embedded_resource?(unwrapped) ->
        build_type_name(unwrapped)

      # Custom types with interop_type_name
      Introspection.is_custom_interop_type?(unwrapped) ->
        unwrapped.interop_type_name()

      # Typed structs
      Introspection.has_field_constraints?(full_constraints) ->
        instance_of = Keyword.get(full_constraints, :instance_of)
        if instance_of, do: build_type_name(instance_of), else: "Map<String, Any>"

      # Unions
      unwrapped == Ash.Type.Union ->
        "Any"  # Or generate sealed class

      # Fallback
      true ->
        "Any"
    end
  end

  defp build_type_name(module) do
    module |> Module.split() |> List.last()
  end
end
```

## Step 3: Code Generation

Generate types and RPC functions:

```elixir
defmodule AshKotlin.Codegen.Generator do
  alias AshIntrospection.Codegen.{TypeDiscovery, ActionIntrospection}
  alias AshKotlin.Codegen.TypeMapper

  def generate(domain, rpc_config) do
    # Discover all types
    {:ok, resources} = TypeDiscovery.scan_rpc_resources(rpc_config.resources, domain)
    embedded = TypeDiscovery.find_embedded_resources(resources, domain)

    # Generate data classes
    type_definitions = Enum.map(embedded, &generate_data_class/1)

    # Generate RPC functions
    rpc_functions = Enum.flat_map(rpc_config.resources, fn {resource, actions} ->
      Enum.map(actions, fn action_config ->
        action = Ash.Resource.Info.action(resource, action_config.action)
        generate_rpc_function(resource, action, action_config)
      end)
    end)

    combine_output(type_definitions, rpc_functions)
  end

  defp generate_data_class(resource) do
    attrs = Ash.Resource.Info.public_attributes(resource)
    name = TypeMapper.build_type_name(resource)

    fields = Enum.map(attrs, fn attr ->
      type = TypeMapper.map_type(attr.type, attr.constraints)
      nullable = if attr.allow_nil?, do: "?", else: ""
      "  val #{to_camel_case(attr.name)}: #{type}#{nullable}"
    end)

    """
    data class #{name}(
    #{Enum.join(fields, ",\n")}
    )
    """
  end

  defp generate_rpc_function(resource, action, config) do
    name = config.name
    input_type = ActionIntrospection.action_input_type(resource, action)

    # Generate based on action type and input requirements
    # ...
  end
end
```

## Step 4: RPC Runtime

Create your language-specific RPC pipeline wrapper:

```elixir
defmodule AshKotlin.Rpc.Pipeline do
  alias AshIntrospection.Rpc.{Pipeline, Request, Errors}
  alias AshIntrospection.Rpc.FieldProcessing.FieldSelector

  @config %{
    input_field_formatter: :camel_case,
    output_field_formatter: :camel_case,
    field_names_callback: :interop_field_names,
    not_found_error?: true
  }

  def execute(params, opts \\ []) do
    with {:ok, request} <- parse_request(params, opts),
         {:ok, result} <- Pipeline.execute_ash_action(request, @config),
         {:ok, processed} <- Pipeline.process_result(result, request, @config) do
      formatted = Pipeline.format_output_with_request(processed, request, @config)
      {:ok, %{success: true, data: formatted}}
    else
      {:error, error} ->
        errors = Errors.to_errors(error, request, @config)
        {:ok, %{success: false, errors: errors}}
    end
  end

  defp parse_request(params, opts) do
    # Stage 1: Parse and validate input
    # This is language-specific!

    with {:ok, {domain, resource, action}} <- discover_action(params),
         {:ok, input} <- parse_input(params, resource, action),
         {:ok, fields} <- parse_fields(params, resource, action) do

      # Process field selection
      {:ok, {select, load, template}} =
        FieldSelector.process(fields, resource, action, @config)

      request = %Request{
        domain: domain,
        resource: resource,
        action: action,
        input: input,
        select: select,
        load: load,
        extraction_template: template,
        actor: opts[:actor],
        tenant: opts[:tenant]
      }

      {:ok, request}
    end
  end
end
```

## Step 5: DSL Extension (Optional)

Add a Spark DSL for configuration:

```elixir
defmodule AshKotlin.Rpc do
  use Spark.Dsl.Extension

  @sections [
    %Spark.Dsl.Section{
      name: :kotlin_rpc,
      entities: [
        %Spark.Dsl.Entity{
          name: :resource,
          args: [:resource],
          schema: [
            resource: [type: :atom, required: true]
          ],
          entities: [
            %Spark.Dsl.Entity{
              name: :rpc_action,
              args: [:name, :action],
              schema: [
                name: [type: :atom, required: true],
                action: [type: :atom, required: true],
                identities: [type: {:list, :atom}, default: [:_primary_key]]
              ]
            }
          ]
        }
      ]
    }
  ]
end
```

## Common Pitfalls

### 1. NewType Unwrapping

Always unwrap NewTypes before type classification:

```elixir
# WRONG - May fail for NewTypes
if Introspection.is_embedded_resource?(type), do: ...

# CORRECT - Unwrap first
{unwrapped, constraints} = Introspection.unwrap_new_type(type, constraints)
if Introspection.is_embedded_resource?(unwrapped), do: ...
```

### 2. Field Name Callback Precedence

Check language-specific callbacks before falling back:

```elixir
# Check typescript_field_names first, then interop_field_names
field_names = cond do
  function_exported?(module, :kotlin_field_names, 0) ->
    module.kotlin_field_names()
  Introspection.has_interop_field_names?(module) ->
    Introspection.get_interop_field_names_map(module)
  true ->
    %{}
end
```

### 3. Constraint Preservation

When processing types, preserve constraints through the pipeline:

```elixir
# Constraints contain important type information
{type, constraints} = Introspection.unwrap_new_type(attr.type, attr.constraints)

# Pass constraints to child processors
inner_constraints = Keyword.get(constraints, :items, [])
process_inner_type(inner_type, inner_constraints)
```

### 4. Cycle Detection in Type Discovery

Always track visited types to prevent infinite loops:

```elixir
defp traverse_types(types, visited \\ MapSet.new()) do
  Enum.flat_map(types, fn type ->
    if MapSet.member?(visited, type) do
      []  # Already visited, skip
    else
      visited = MapSet.put(visited, type)
      [type | traverse_types(get_nested_types(type), visited)]
    end
  end)
end
```

### 5. Identity Handling for Updates/Deletes

Support multiple identity types:

```elixir
# Primary key (simple value)
identity: "uuid-123"

# Primary key (composite)
identity: %{org_id: "org-1", user_id: "user-1"}

# Named identity
identity: %{email: "user@example.com"}
```

### 6. Pagination Response Handling

Handle both paginated and non-paginated responses:

```elixir
case result do
  %Ash.Page.Offset{results: results, count: count} ->
    %{results: process_results(results), count: count}

  %Ash.Page.Keyset{results: results} ->
    %{results: process_results(results)}

  results when is_list(results) ->
    process_results(results)

  single_result ->
    process_result(single_result)
end
```

### 7. Error Field Path Formatting

Convert field paths to client format:

```elixir
# Ash returns: [:user, :address, :street]
# Client expects: ["user", "address", "street"] with camelCase
path = Enum.map(error.path, fn
  field when is_atom(field) -> to_camel_case(field)
  index when is_integer(index) -> Integer.to_string(index)
end)
```

### 8. Generic Action Return Types

Not all generic actions return field-selectable types:

```elixir
case ActionIntrospection.action_returns_field_selectable_type?(action) do
  {:ok, :resource, module} ->
    # Can select fields, generate typed response
    generate_typed_response(module)

  {:ok, :typed_map, fields} ->
    # Can select fields from inline type
    generate_inline_response(fields)

  {:error, :not_field_selectable_type} ->
    # Returns primitive, no field selection
    generate_primitive_response(action.returns)

  {:error, :not_generic_action} ->
    # Not a generic action, use standard CRUD handling
    handle_crud_action(action)
end
```

## Requirements

- Elixir 1.15 or later
- Ash 3.0 or later

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes with tests
4. Ensure all tests pass (`mix test`)
5. Run code formatter (`mix format`)
6. Open a Pull Request

## License

This project is licensed under the MIT License.

## Support

- **Documentation**: [https://hexdocs.pm/ash_introspection](https://hexdocs.pm/ash_introspection)
- **GitHub Issues**: [https://github.com/ash-project/ash_introspection/issues](https://github.com/ash-project/ash_introspection/issues)
- **Discord**: [Ash Framework Discord](https://discord.gg/HTHRaaVPUc)
