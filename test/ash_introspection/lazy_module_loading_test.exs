# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.LazyModuleLoadingTest do
  @moduledoc """
  The sweep #49 asked for, beyond the `Errors` site the issue named.

  Every callback this library reads off a module the consumer supplied — a
  type's field-names callback, a struct's `interop_field_names/0`, a
  `resource_info_module` handed in through config — was gated on
  `function_exported?/3` alone. Elixir loads modules lazily, so each of those
  answered `false` on a cold VM and the caller silently got the fallback.

  Each test unloads the module first and never calls `Code.ensure_loaded!/1`,
  which would load it and hide the bug. `async: false` because unloading a
  module is global to the VM.
  """
  use ExUnit.Case, async: false

  alias AshIntrospection.Rpc.FieldProcessing.Atomizer
  alias AshIntrospection.Rpc.ResultProcessor
  alias AshIntrospection.Test.Account
  alias AshIntrospection.Test.LazyLoadedFieldNames
  alias AshIntrospection.Test.LazyLoadedResourceInfo
  alias AshIntrospection.Test.LazyLoadedStruct
  alias AshIntrospection.TypeSystem.Introspection

  describe "a type the VM has not loaded" do
    test "still yields its field names map" do
      unload!(LazyLoadedFieldNames)

      assert Introspection.get_field_names_map(LazyLoadedFieldNames, :typescript_field_names) ==
               %{is_active?: "isActive"}
    end
  end

  describe "a struct whose module the VM has not loaded" do
    test "is still recognised as a typed struct" do
      # Built before the unload: a struct literal is expanded at compile time,
      # so holding the value never loads the module it names.
      data = %LazyLoadedStruct{name: "Alice"}

      unload!(LazyLoadedStruct)

      assert ResultProcessor.determine_data_type(data, nil, %{}) ==
               {Ash.Type.Struct, [instance_of: LazyLoadedStruct]}
    end
  end

  describe "a resource_info_module the VM has not loaded" do
    test "still maps a client field name back to its internal name" do
      unload!(LazyLoadedResourceInfo)

      assert Atomizer.atomize_requested_fields(["givenName"], Account, %{
               resource_info_module: LazyLoadedResourceInfo
             }) == [:given_name]
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
