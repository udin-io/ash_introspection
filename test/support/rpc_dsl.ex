# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.RpcDsl do
  @moduledoc """
  Minimal stand-in for the `typescript_rpc` DSL section that consuming
  libraries (`ash_typescript`, `ash_kotlin_multiplatform`) define.

  `AshIntrospection.Rpc.Errors` reads `show_raised_errors?` and `error_handler`
  off the caller's domain with `Spark.Dsl.Extension.fetch_opt/3`, so exercising
  those branches needs a real Spark extension rather than a stub module — this
  library ships no DSL of its own.
  """

  @typescript_rpc %Spark.Dsl.Section{
    name: :typescript_rpc,
    describe: "Test-only mirror of a consumer's RPC configuration section.",
    schema: [
      show_raised_errors?: [
        type: :boolean,
        default: false,
        doc: "Expose the raised exception's own message to the client."
      ],
      error_handler: [
        type: :any,
        doc: "Module, or {module, function, args}, applied to every error."
      ]
    ]
  }

  use Spark.Dsl.Extension, sections: [@typescript_rpc]
end

defmodule AshIntrospection.Test.RaisingErrorsDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshIntrospection.Test.RpcDsl], validate_config_inclusion?: false

  typescript_rpc do
    show_raised_errors?(true)
  end

  resources do
  end
end

defmodule AshIntrospection.Test.LazyLoadedErrorHandler do
  @moduledoc """
  Domain-level `error_handler` for the lazy-loading tests. Rewrites every
  message so a test can tell the configured handler from the default one.
  """

  def handle_error(error, _context), do: %{error | message: "handled by the domain"}
end

defmodule AshIntrospection.Test.LazyLoadedRaisingDomain do
  @moduledoc """
  Domain used only by `AshIntrospection.Rpc.ErrorsLazyModuleLoadingTest`, which
  unloads it from the VM. It is separate from `RaisingErrorsDomain` so that
  unloading cannot race another test that reads the same module.
  """
  use Ash.Domain, extensions: [AshIntrospection.Test.RpcDsl], validate_config_inclusion?: false

  typescript_rpc do
    show_raised_errors?(true)
  end

  resources do
  end
end

defmodule AshIntrospection.Test.LazyLoadedHandlerDomain do
  @moduledoc """
  Domain carrying only an `error_handler`, so a test can tell the configured
  handler from the default one without `show_raised_errors?` also rewriting the
  message.
  """
  use Ash.Domain, extensions: [AshIntrospection.Test.RpcDsl], validate_config_inclusion?: false

  typescript_rpc do
    error_handler(AshIntrospection.Test.LazyLoadedErrorHandler)
  end

  resources do
  end
end

defmodule AshIntrospection.Test.LazyLoadedErrorResource do
  @moduledoc """
  Stands in for a consumer resource that defines `handle_rpc_error/2`. Not an
  Ash resource: `Errors` reaches the callback off any module the caller passes.
  """

  def handle_rpc_error(error, _context), do: %{error | message: "handled by the resource"}
end

defmodule AshIntrospection.Test.LazyLoadedFieldNames do
  @moduledoc """
  Stands in for a consumer type that declares a field-names callback, for the
  `Introspection.get_field_names_map/2` lazy-loading test.
  """

  def typescript_field_names, do: %{is_active?: "isActive"}
end
