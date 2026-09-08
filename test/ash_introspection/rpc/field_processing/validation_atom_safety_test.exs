# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.FieldProcessing.ValidationAtomSafetyTest do
  @moduledoc """
  Regression coverage for issue #10 at the duplicate-name check.

  `check_for_duplicates/3` runs before any field-existence check, so it saw
  every client-supplied name including garbage. Normalising those names through
  the old `convert_to_field_atom/2` minted an atom per name on every request.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.FieldProcessing.Validation

  defp atom_exists?(name) when is_binary(name) do
    _ = String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end

  defp unknown_name(prefix), do: "#{prefix}#{System.unique_integer([:positive])}Zz"

  describe "check_for_duplicates/3" do
    test "accepts unknown field names without minting atoms" do
      names = for _ <- 1..200, do: unknown_name("atomBombDup")

      assert :ok = Validation.check_for_duplicates(names, [], %{})

      Enum.each(names, fn name ->
        refute atom_exists?(Macro.underscore(name))
      end)
    end

    test "accepts unknown keys in nested field maps without minting atoms" do
      names = for _ <- 1..200, do: unknown_name("atomBombNested")
      fields = Enum.map(names, fn name -> %{name => ["id"]} end)

      assert :ok = Validation.check_for_duplicates(fields, [], %{})

      Enum.each(names, fn name ->
        refute atom_exists?(Macro.underscore(name))
      end)
    end

    test "still reports a repeated unknown name as a duplicate" do
      name = unknown_name("atomBombRepeat")

      assert catch_throw(Validation.check_for_duplicates([name, name], [:foo], %{})) ==
               {:duplicate_field, Macro.underscore(name), [:foo]}
    end

    test "still reports a known name repeated across formats as a duplicate" do
      assert catch_throw(
               Validation.check_for_duplicates(["userName", :user_name], [], %{
                 input_field_formatter: :camel_case
               })
             ) == {:duplicate_field, :user_name, []}
    end
  end
end
