# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.TypeSystem.ResourceFieldsTest do
  use ExUnit.Case, async: true

  alias AshIntrospection.Test.LoadThrough
  alias AshIntrospection.TypeSystem.ResourceFields

  describe "get_field_type_info/2" do
    test "returns type info for attributes" do
      {type, constraints} =
        ResourceFields.get_field_type_info(AshIntrospection.Test.User, :name)

      assert Ash.Type.String == type
      assert is_list(constraints)
    end

    test "returns type info for relationships" do
      {type, constraints} =
        ResourceFields.get_field_type_info(AshIntrospection.Test.User, :address)

      assert AshIntrospection.Test.Address == type
      assert [] == constraints
    end

    test "returns {nil, []} for unknown fields" do
      {type, constraints} =
        ResourceFields.get_field_type_info(AshIntrospection.Test.User, :unknown_field)

      assert nil == type
      assert [] == constraints
    end
  end

  describe "a first aggregate over a union" do
    test "get_field_type_info/3 returns the union and its members" do
      {type, constraints} = ResourceFields.get_field_type_info(LoadThrough.Owner, :first_extra)

      assert type == Ash.Type.Union
      assert Keyword.keys(constraints[:types]) == [:tag, :note]
    end

    test "get_public_field_type_info/3 returns the union and its members" do
      {type, constraints} =
        ResourceFields.get_public_field_type_info(LoadThrough.Owner, :first_extra)

      assert type == Ash.Type.Union
      assert Keyword.keys(constraints[:types]) == [:tag, :note]
    end
  end

  describe "get_public_field_type_info/2" do
    test "returns type info for public attributes" do
      {type, _constraints} =
        ResourceFields.get_public_field_type_info(AshIntrospection.Test.User, :name)

      assert Ash.Type.String == type
    end

    test "returns type info for public relationships" do
      {type, _constraints} =
        ResourceFields.get_public_field_type_info(AshIntrospection.Test.User, :address)

      assert AshIntrospection.Test.Address == type
    end

    test "returns {nil, []} for unknown fields" do
      {type, constraints} =
        ResourceFields.get_public_field_type_info(AshIntrospection.Test.User, :unknown)

      assert nil == type
      assert [] == constraints
    end
  end

  describe "get_aggregate_type_info/2" do
    test "returns type info for aggregates" do
      {type, _constraints} =
        ResourceFields.get_aggregate_type_info(AshIntrospection.Test.User, :address_count)

      assert type != nil
    end

    test "unwraps the resolved type of a count" do
      assert ResourceFields.get_aggregate_type_info(LoadThrough.Owner, :item_count) ==
               {Ash.Type.Integer, []}
    end

    test "types a first aggregate by the field it reads, constraints included" do
      {type, constraints} =
        ResourceFields.get_aggregate_type_info(LoadThrough.Owner, :first_extra)

      assert type == Ash.Type.Union
      assert Keyword.keys(constraints[:types]) == [:tag, :note]
    end

    test "types a list aggregate as an array of the field it reads" do
      tag_constraints = Ash.Resource.Info.attribute(LoadThrough.Item, :tag).constraints

      assert ResourceFields.get_aggregate_type_info(LoadThrough.Owner, :all_item_tags) ==
               {{:array, LoadThrough.Tag}, [items: tag_constraints]}
    end

    test "returns {nil, []} for unknown aggregates" do
      {type, constraints} =
        ResourceFields.get_aggregate_type_info(AshIntrospection.Test.User, :unknown)

      assert nil == type
      assert [] == constraints
    end
  end
end
