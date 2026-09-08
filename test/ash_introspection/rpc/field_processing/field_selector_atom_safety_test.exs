# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.FieldProcessing.FieldSelectorAtomSafetyTest do
  @moduledoc """
  Regression coverage for issue #10 through the public entry point,
  `FieldSelector.process/4`.

  Every field name in a request reaches this module before anything has checked
  it against a real field. Minting an atom per name let an unauthenticated
  caller fill the atom table, which is never garbage collected, and take the
  node down. Each selection path gets its own case because each resolves names
  differently.

  The batch cases assert on `:erlang.system_info(:atom_count)`, so this module is
  synchronous — a concurrent module compiling or resolving atoms would move that
  number.
  """
  use ExUnit.Case, async: false

  alias AshIntrospection.Rpc.FieldProcessing.FieldSelector
  alias AshIntrospection.Test.Post

  @batch_size 500

  defp atom_exists?(name) when is_binary(name) do
    _ = String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end

  defp unknown_name(prefix), do: "#{prefix}#{System.unique_integer([:positive])}Zz"

  # A name is only safe if neither the wire form nor the internal snake_case form
  # gained an atom - the old code minted the latter.
  defp refute_atoms_for(name) do
    refute atom_exists?(name)
    refute atom_exists?(Macro.underscore(name))
  end

  # Runs `fun` once to settle any first-call atom creation in Ash or the error
  # path, then asserts the next `@batch_size` distinct names add no atoms.
  defp assert_no_atoms_minted(fun) do
    fun.(unknown_name("atomBombWarmup"))

    before = :erlang.system_info(:atom_count)

    for _ <- 1..@batch_size do
      fun.(unknown_name("atomBombBatch"))
    end

    assert :erlang.system_info(:atom_count) == before
  end

  describe "typed map fields" do
    test "an unknown field name is rejected without minting an atom" do
      name = unknown_name("atomBombTypedMap")

      assert {:error, {:unknown_field, unknown, "map", []}} =
               FieldSelector.process(Post, :get_stats, [name])

      assert is_binary(unknown)
      refute_atoms_for(name)
    end

    test "a batch of unknown field names mints no atoms" do
      assert_no_atoms_minted(fn name ->
        assert {:error, {:unknown_field, _, _, _}} =
                 FieldSelector.process(Post, :get_stats, [name])
      end)
    end

    test "an unknown nested field name is rejected without minting an atom" do
      name = unknown_name("atomBombNestedTypedMap")

      assert {:error, {:unknown_field, unknown, "map", []}} =
               FieldSelector.process(Post, :get_stats, [%{name => ["id"]}])

      assert is_binary(unknown)
      refute_atoms_for(name)
    end

    test "known field names still resolve" do
      assert {:ok, {_select, _load, template}} =
               FieldSelector.process(Post, :get_stats, ["totalPosts", "draftCount"])

      assert template == [:total_posts, :draft_count]
    end
  end

  describe "tuple fields" do
    test "an unknown field name is rejected without minting an atom" do
      name = unknown_name("atomBombTuple")

      assert {:error, {:unknown_field, unknown, "tuple", []}} =
               FieldSelector.process(Post, :get_bounds, [name])

      assert is_binary(unknown)
      refute_atoms_for(name)
    end

    test "a batch of unknown field names mints no atoms" do
      assert_no_atoms_minted(fn name ->
        assert {:error, {:unknown_field, _, _, _}} =
                 FieldSelector.process(Post, :get_bounds, [name])
      end)
    end

    test "known field names still resolve" do
      assert {:ok, {_select, _load, template}} =
               FieldSelector.process(Post, :get_bounds, ["latitude", "longitude"])

      assert template == [
               %{field_name: :latitude, index: 0},
               %{field_name: :longitude, index: 1}
             ]
    end
  end
end
