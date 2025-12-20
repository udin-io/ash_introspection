# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection do
  @moduledoc """
  Shared core library for Ash interoperability with multiple languages.

  This library provides the foundational modules used by language-specific
  generators like `AshTypescript` and `AshKotlinMultiplatform`.

  ## Type System

  - `AshIntrospection.TypeSystem.Introspection` - Centralized type classification
  - `AshIntrospection.TypeSystem.ResourceFields` - Resource field lookup

  ## RPC Runtime

  - `AshIntrospection.Rpc.Request` - Request data structure for RPC pipeline
  - `AshIntrospection.Rpc.Pipeline` - Language-agnostic 4-stage RPC pipeline
  - `AshIntrospection.Rpc.ValueFormatter` - Bidirectional type-driven value formatting
  - `AshIntrospection.Rpc.ResultProcessor` - Field extraction from results
  - `AshIntrospection.Rpc.FieldExtractor` - Unified field extraction for data structures
  - `AshIntrospection.Rpc.ErrorBuilder` - Comprehensive error handling
  - `AshIntrospection.Rpc.Errors` - Central error processing
  - `AshIntrospection.Rpc.Error` - Error protocol for custom error types
  - `AshIntrospection.Rpc.DefaultErrorHandler` - Pass-through error handler

  ## Field Processing

  - `AshIntrospection.Rpc.FieldProcessing.Atomizer` - Field name atomization
  - `AshIntrospection.Rpc.FieldProcessing.FieldSelector` - Type-driven field selection
  - `AshIntrospection.Rpc.FieldProcessing.Validation` - Field validation helpers

  ## Code Generation

  - `AshIntrospection.Codegen.TypeDiscovery` - Resource and type scanning

  ## Formatting

  - `AshIntrospection.FieldFormatter` - Field name transformation utilities
  - `AshIntrospection.Helpers` - Case conversion utilities
  """
end
