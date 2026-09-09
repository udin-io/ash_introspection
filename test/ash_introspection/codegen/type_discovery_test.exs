# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Codegen.TypeDiscoveryTest do
  @moduledoc """
  Discovery tests for issue #21. Each test names one route by which a type
  reaches an entrypoint resource, and one embedded resource reachable only by
  that route.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Codegen.TypeDiscovery

  alias AshIntrospection.Test.{
    Document,
    EmbeddedAttachment,
    EmbeddedAudit,
    EmbeddedFilter,
    EmbeddedNote,
    EmbeddedRendered,
    EmbeddedUnscoped,
    Ledger,
    User,
    WrappedContent
  }

  defp config, do: %{get_rpc_resources: fn _otp_app -> [Document] end}

  defp action(name), do: Ash.Resource.Info.action(Document, name)

  describe "NewType-wrapped unions" do
    test "traverse_type/2 finds members of a union hidden behind a NewType" do
      assert TypeDiscovery.traverse_type(WrappedContent, []) == [EmbeddedNote]
    end

    test "traverse_type/2 finds members through an array of NewType-wrapped unions" do
      assert TypeDiscovery.traverse_type({:array, WrappedContent}, []) == [EmbeddedNote]
    end

    test "find_embedded_resources/2 reaches a union member behind a NewType attribute" do
      assert EmbeddedNote in TypeDiscovery.find_embedded_resources(:ash_introspection, config())
    end
  end

  describe "struct arguments" do
    test "find_struct_argument_resources/1 finds an embedded resource used directly" do
      assert EmbeddedAttachment in TypeDiscovery.find_struct_argument_resources([action(:attach)])
    end

    test "find_struct_argument_resources/1 unwraps a NewType over a struct" do
      assert User in TypeDiscovery.find_struct_argument_resources([action(:attach)])
    end
  end

  describe "types reachable only through an action or a calculation argument" do
    setup do
      %{discovered: TypeDiscovery.find_embedded_resources(:ash_introspection, config())}
    end

    test "finds the type of a calculation argument", %{discovered: discovered} do
      assert EmbeddedFilter in discovered
    end

    test "finds the type of a generic action argument", %{discovered: discovered} do
      assert EmbeddedAttachment in discovered
    end

    test "finds a generic action's return type", %{discovered: discovered} do
      assert EmbeddedRendered in discovered
    end

    test "finds the type of a read action's metadata", %{discovered: discovered} do
      assert EmbeddedAudit in discovered
    end
  end

  describe "entrypoint scoping" do
    defp entrypoint_config(resources, entrypoints) do
      %{
        get_rpc_resources: fn _otp_app -> resources end,
        get_rpc_action_entrypoints: fn _otp_app -> entrypoints end
      }
    end

    test "without declared entrypoints every public action and field is in scope" do
      discovered =
        TypeDiscovery.find_embedded_resources(
          :ash_introspection,
          %{get_rpc_resources: fn _otp_app -> [Ledger] end}
        )

      assert EmbeddedUnscoped in discovered
    end

    test "a generic action entrypoint does not reach the resource's own fields" do
      config = entrypoint_config([Ledger], [%{resource: Ledger, action: :ping}])

      refute EmbeddedUnscoped in TypeDiscovery.find_embedded_resources(:ash_introspection, config)
    end

    test "a read action entrypoint does reach the resource's own fields" do
      config = entrypoint_config([Ledger], [%{resource: Ledger, action: :read}])

      assert EmbeddedUnscoped in TypeDiscovery.find_embedded_resources(:ash_introspection, config)
    end

    test "a resource with no declared entrypoint contributes nothing" do
      config = entrypoint_config([Document, Ledger], [%{resource: Document, action: :attach}])
      discovered = TypeDiscovery.find_embedded_resources(:ash_introspection, config)

      assert EmbeddedAttachment in discovered
      refute EmbeddedUnscoped in discovered
    end

    test "entrypoints may be given as {resource, action} tuples" do
      config = entrypoint_config([Ledger], [{Ledger, :read}])

      assert EmbeddedUnscoped in TypeDiscovery.find_embedded_resources(:ash_introspection, config)
    end
  end
end
