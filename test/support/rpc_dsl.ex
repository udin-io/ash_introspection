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
