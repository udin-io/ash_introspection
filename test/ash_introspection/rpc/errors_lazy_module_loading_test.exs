# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.LazyLoadingError do
  @moduledoc false
  defexception [:message, :path]
end

defmodule AshIntrospection.Rpc.ErrorsLazyModuleLoadingTest do
  @moduledoc """
  Configuration a consumer sets must be honoured on a cold VM.

  `Errors` reads `show_raised_errors?`, `error_handler` and `handle_rpc_error/2`
  off modules the caller supplies, and gated each read on `function_exported?/3`
  alone. Elixir loads modules lazily, so that answers `false` for a domain or
  resource nothing in the current process has touched: the configuration was
  silently ignored, and the same call returned different errors on a warm VM
  than on a cold one (#49).

  Every test here unloads the module first and never calls
  `Code.ensure_loaded!/1` — doing so would load the module and hide the bug.
  The file is `async: false` because unloading a module is global to the VM.
  """
  use ExUnit.Case, async: false

  alias AshIntrospection.Rpc.Errors
  alias AshIntrospection.Test.LazyLoadedErrorResource
  alias AshIntrospection.Test.LazyLoadedHandlerDomain
  alias AshIntrospection.Test.LazyLoadedRaisingDomain
  alias AshIntrospection.Test.LazyLoadingError

  @config %{rpc_dsl_section: :typescript_rpc}

  describe "a domain the VM has not loaded" do
    test "still has its show_raised_errors? honoured" do
      unload!(LazyLoadedRaisingDomain)

      [error] =
        Errors.to_errors(
          LazyLoadingError.exception(message: "shown to the client"),
          LazyLoadedRaisingDomain,
          nil,
          nil,
          %{},
          @config
        )

      assert error.message =~ "shown to the client"
    end

    test "still has its error_handler applied" do
      unload!(LazyLoadedHandlerDomain)

      [error] =
        Errors.to_errors(
          LazyLoadingError.exception(message: "hidden from the client"),
          LazyLoadedHandlerDomain,
          nil,
          nil,
          %{},
          @config
        )

      assert error.message == "handled by the domain"
    end
  end

  describe "a resource the VM has not loaded" do
    test "still has its handle_rpc_error/2 applied" do
      unload!(LazyLoadedErrorResource)

      [error] =
        Errors.to_errors(
          LazyLoadingError.exception(message: "hidden from the client"),
          nil,
          LazyLoadedErrorResource,
          nil,
          %{},
          @config
        )

      assert error.message == "handled by the resource"
    end
  end

  # `:code.delete/1` moves the current version to old; the purges drop the old
  # copy either side of it, so `:erlang.module_loaded/1` answers false and the
  # next call has to load the module from disk to see anything on it.
  defp unload!(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)

    refute :erlang.module_loaded(module),
           "#{inspect(module)} is still loaded; the test would not reach the branch it covers"

    on_exit(fn -> Code.ensure_loaded(module) end)
  end
end
