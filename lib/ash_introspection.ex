# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection do
  @moduledoc """
  Shared core library for Ash interoperability with multiple languages.

  This library provides the foundational modules used by language-specific
  generators like `AshTypescript` and `AshKotlinMultiplatform`:

  - `AshIntrospection.TypeSystem.Introspection` - Centralized type classification
  - `AshIntrospection.Codegen.TypeDiscovery` - Resource and type scanning
  - `AshIntrospection.FieldFormatter` - Field name transformation utilities
  - `AshIntrospection.Helpers` - Case conversion utilities
  """
end
