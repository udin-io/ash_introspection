# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.FieldFormatterAtomSafetyTest do
  @moduledoc """
  Regression coverage for issue #10: a client-supplied field name must never
  mint a new atom. The atom table is never garbage collected, so one request per
  unique name is an unauthenticated denial of service against the whole node.

  Per-name assertions probe `String.to_existing_atom/1` rather than sampling the
  global atom count, which concurrent test modules would perturb.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.FieldFormatter

  defp atom_exists?(name) when is_binary(name) do
    _ = String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end

  describe "resolve_field_name/2" do
    test "resolves a camelCase name to the existing atom" do
      # The atom exists because this module names it.
      _ = :user_name
      assert FieldFormatter.resolve_field_name("userName", :camel_case) == :user_name
    end

    test "passes atoms through unchanged" do
      assert FieldFormatter.resolve_field_name(:already_atom, :camel_case) == :already_atom
    end

    test "returns the formatted string for an unknown name without minting an atom" do
      name = "atomBombFieldName#{System.unique_integer([:positive])}Xyz"

      result = FieldFormatter.resolve_field_name(name, :camel_case)

      assert is_binary(result)
      refute atom_exists?(result)
    end

    test "mints no atoms for a batch of unique unknown names" do
      names = for i <- 1..1000, do: "atomBombBatch#{i}Zz#{System.unique_integer([:positive])}"

      Enum.each(names, fn name ->
        result = FieldFormatter.resolve_field_name(name, :camel_case)
        assert is_binary(result)
        refute atom_exists?(result)
      end)
    end

    test "handles names longer than the 255-character atom limit" do
      long = String.duplicate("a", 300)

      assert FieldFormatter.resolve_field_name(long, :camel_case) == long
    end
  end
end
