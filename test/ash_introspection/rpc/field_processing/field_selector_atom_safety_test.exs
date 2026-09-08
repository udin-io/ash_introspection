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
  alias AshIntrospection.Test.User

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

  # Runs a full warm-up batch first: Ash's own lazy initialisation creates a few
  # hundred atoms the first time a selection path runs, and only then does the
  # count settle. Every batch after that must add exactly zero, which is what
  # separates a fixed path from one minting an atom per name.
  defp assert_no_atoms_minted(fun) do
    run_batch(fun, "atomBombWarmup")

    before = :erlang.system_info(:atom_count)
    names = run_batch(fun, "atomBombBatch")

    assert :erlang.system_info(:atom_count) == before
    Enum.each(names, &refute_atoms_for/1)
  end

  defp run_batch(fun, prefix) do
    for _ <- 1..@batch_size do
      name = unknown_name(prefix)
      fun.(name)
      name
    end
  end

  describe "resource fields" do
    test "an unknown field name is rejected without minting an atom" do
      name = unknown_name("atomBombResource")

      assert {:error, {:unknown_field, unknown, User, []}} =
               FieldSelector.process(User, :read, [name])

      assert is_binary(unknown)
      refute_atoms_for(name)
    end

    test "a batch of unknown field names mints no atoms" do
      assert_no_atoms_minted(fn name ->
        assert {:error, {:unknown_field, _, _, _}} = FieldSelector.process(User, :read, [name])
      end)
    end

    test "an unknown nested field name is rejected without minting an atom" do
      name = unknown_name("atomBombNestedResource")

      assert {:error, {:unknown_field, unknown, User, []}} =
               FieldSelector.process(User, :read, [%{name => ["id"]}])

      assert is_binary(unknown)
      refute_atoms_for(name)
    end

    test "known attribute and aggregate names still resolve" do
      assert {:ok, {select, load, template}} =
               FieldSelector.process(User, :read, ["id", "name", "isActive", "addressCount"])

      assert select == [:id, :name, :is_active]
      assert load == [:address_count]
      assert template == [:id, :name, :is_active, :address_count]
    end

    test "known relationship names still resolve" do
      assert {:ok, {_select, load, template}} =
               FieldSelector.process(User, :read, [%{"address" => ["street", "city"]}])

      assert load == [{:address, [:street, :city]}]
      assert template == [address: [:street, :city]]
    end
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

  describe "typed struct fields" do
    test "an unknown field name is rejected without minting an atom" do
      name = unknown_name("atomBombTypedStruct")

      assert {:error, {:unknown_field, unknown, "field_constrained_type", []}} =
               FieldSelector.process(Post, :get_task_stats, [name])

      assert is_binary(unknown)
      refute_atoms_for(name)
    end

    test "a batch of unknown field names mints no atoms" do
      assert_no_atoms_minted(fn name ->
        assert {:error, {:unknown_field, _, _, _}} =
                 FieldSelector.process(Post, :get_task_stats, [name])
      end)
    end

    test "mapped field names still resolve to their internal atoms" do
      assert {:ok, {_select, _load, template}} =
               FieldSelector.process(Post, :get_task_stats, ["isActive", "taskCount", "meta1"])

      assert template == [:is_active?, :task_count, :meta_1]
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
