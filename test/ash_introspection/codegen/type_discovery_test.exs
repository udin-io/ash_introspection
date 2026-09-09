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
    EmbeddedNote,
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
end
