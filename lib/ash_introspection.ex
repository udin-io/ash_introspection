# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection do
  @moduledoc """
  Shared core library for Ash interoperability with multiple languages.

  AshIntrospection provides the foundational modules used by language-specific
  generators like `AshTypescript` and `AshKotlinMultiplatform`. It enables
  seamless RPC communication between Elixir/Ash backends and clients in other
  languages through:

  - **Unified type introspection** - Consistent type classification and analysis
  - **Language-agnostic RPC pipeline** - Execute Ash actions with field selection
  - **Bidirectional field name mapping** - Convert between snake_case and camelCase
  - **Type-driven value formatting** - Format values based on their Ash types
  - **Comprehensive error handling** - Standardized error responses

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

  ## Module Categories

  ### Type System

  Modules for analyzing and classifying Ash types:

  - `AshIntrospection.TypeSystem.Introspection` - Core type classification,
    NewType unwrapping, union type extraction, and field name callback detection

  - `AshIntrospection.TypeSystem.ResourceFields` - Unified resource field lookup
    for attributes, calculations, relationships, and aggregates

  ### RPC Runtime

  Modules for executing Ash actions via RPC:

  - `AshIntrospection.Rpc.Request` - Request data structure containing domain,
    resource, action, input, field selection, and query parameters

  - `AshIntrospection.Rpc.Pipeline` - Language-agnostic 4-stage pipeline that
    executes actions, processes results, and formats output

  - `AshIntrospection.Rpc.ValueFormatter` - Bidirectional type-driven value
    formatting for input parsing and output generation

  - `AshIntrospection.Rpc.ResultProcessor` - Field extraction from action results
    using pre-computed extraction templates

  - `AshIntrospection.Rpc.FieldExtractor` - Unified field extraction for maps,
    structs, keyword lists, and tuples

  ### Field Processing

  Modules for handling field selection and validation:

  - `AshIntrospection.Rpc.FieldProcessing.Atomizer` - Converts client field names
    to atoms while preserving original strings for reverse mapping

  - `AshIntrospection.Rpc.FieldProcessing.FieldSelector` - Type-driven recursive
    field selection with validation for all composite types

  - `AshIntrospection.Rpc.FieldProcessing.Validation` - Duplicate detection and
    field existence validation

  ### Error Handling

  Modules for standardized error responses:

  - `AshIntrospection.Rpc.Error` - Protocol for extracting information from
    exceptions into standardized format

  - `AshIntrospection.Rpc.ErrorBuilder` - Comprehensive error message generation
    for all error types

  - `AshIntrospection.Rpc.Errors` - Central error processing pipeline with
    variable interpolation and custom handlers

  - `AshIntrospection.Rpc.DefaultErrorHandler` - Pass-through handler for
    unmodified error responses

  ### Code Generation

  Modules for type discovery and action analysis:

  - `AshIntrospection.Codegen.TypeDiscovery` - Recursive scanning of resources
    and types for code generation, with cycle detection and path tracking

  - `AshIntrospection.Codegen.ActionIntrospection` - Analysis of action
    characteristics including pagination, input requirements, and return types

  - `AshIntrospection.Codegen.ValidationErrorTypes` - Language-agnostic
    classification of validation error types for code generation

  ### Formatting Utilities

  Modules for field name transformation:

  - `AshIntrospection.FieldFormatter` - Field name formatting with built-in
    formatters (camelCase, PascalCase, snake_case) and custom formatter support

  - `AshIntrospection.Helpers` - Low-level case conversion utilities

  ## Key Design Patterns

  ### Type-Driven Dispatch

  Many modules use a unified dispatch pattern based on `{type, constraints}` tuples.
  This makes types self-describing and enables consistent handling across:

  - `ValueFormatter` - Format values for input/output
  - `ResultProcessor` - Extract fields from results
  - `FieldSelector` - Validate field selections
  - `ValidationErrorTypes` - Classify error types

  ### Configuration via Maps

  The RPC pipeline accepts configuration maps for language-specific behavior:

  ```elixir
  %{
    input_field_formatter: :camel_case,
    output_field_formatter: :camel_case,
    field_names_callback: :interop_field_names,
    get_original_field_name: fn resource, client_key -> ... end,
    format_field_for_client: fn field_name, resource, formatter -> ... end,
    not_found_error?: true
  }
  ```

  ### Field Name Callbacks

  Types can define callbacks for field name mapping:

  - `interop_field_names/0` - Generalized callback for all languages
  - `typescript_field_names/0` - TypeScript-specific (falls back to interop)
  - `interop_type_name/0` - Custom type name for code generation

  ## Installation

  Add to your `mix.exs`:

  ```elixir
  def deps do
    [
      {:ash_introspection, "~> 0.2"}
    ]
  end
  ```

  ## Usage

  This library is primarily used as a dependency by language-specific generators.
  See the documentation for each module for direct usage patterns.
  """
end
