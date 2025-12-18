# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.TypeSystem.IntrospectionTest do
  use ExUnit.Case, async: true

  alias AshIntrospection.TypeSystem.Introspection

  describe "is_embedded_resource?/1" do
    test "returns true for embedded resources" do
      assert Introspection.is_embedded_resource?(AshIntrospection.Test.EmbeddedAddress)
    end

    test "returns false for non-embedded resources" do
      refute Introspection.is_embedded_resource?(AshIntrospection.Test.User)
    end

    test "returns false for non-resources" do
      refute Introspection.is_embedded_resource?(String)
      refute Introspection.is_embedded_resource?(nil)
    end
  end

  describe "is_primitive_type?/1" do
    test "returns true for primitive types" do
      assert Introspection.is_primitive_type?(Ash.Type.String)
      assert Introspection.is_primitive_type?(Ash.Type.Integer)
      assert Introspection.is_primitive_type?(Ash.Type.Boolean)
      assert Introspection.is_primitive_type?(Ash.Type.Float)
      assert Introspection.is_primitive_type?(Ash.Type.Decimal)
      assert Introspection.is_primitive_type?(Ash.Type.Date)
      assert Introspection.is_primitive_type?(Ash.Type.DateTime)
      assert Introspection.is_primitive_type?(Ash.Type.UUID)
    end

    test "returns false for complex types" do
      refute Introspection.is_primitive_type?(Ash.Type.Union)
      refute Introspection.is_primitive_type?(Ash.Type.Map)
      refute Introspection.is_primitive_type?(Ash.Type.Struct)
    end
  end

  describe "classify_ash_type/3" do
    test "returns :union_attribute for union types" do
      assert :union_attribute == Introspection.classify_ash_type(Ash.Type.Union, %{}, false)
    end

    test "returns :embedded_resource for embedded resources" do
      assert :embedded_resource ==
               Introspection.classify_ash_type(
                 AshIntrospection.Test.EmbeddedAddress,
                 %{},
                 false
               )
    end

    test "returns :embedded_resource_array for embedded resources in arrays" do
      assert :embedded_resource_array ==
               Introspection.classify_ash_type(
                 AshIntrospection.Test.EmbeddedAddress,
                 %{},
                 true
               )
    end

    test "returns :tuple for tuple types" do
      assert :tuple == Introspection.classify_ash_type(Ash.Type.Tuple, %{}, false)
    end

    test "returns :attribute for other types" do
      assert :attribute == Introspection.classify_ash_type(Ash.Type.String, %{}, false)
    end
  end

  describe "get_union_types/1" do
    test "extracts types from union attribute" do
      attribute = %{
        type: Ash.Type.Union,
        constraints: [types: [note: [type: :string], url: [type: :string]]]
      }

      union_types = Introspection.get_union_types(attribute)
      assert [note: [type: :string], url: [type: :string]] == union_types
    end

    test "returns empty list for non-union types" do
      attribute = %{type: Ash.Type.String, constraints: []}
      assert [] == Introspection.get_union_types(attribute)
    end
  end

  describe "get_inner_type/1" do
    test "extracts inner type from array" do
      assert Ash.Type.String == Introspection.get_inner_type({:array, Ash.Type.String})
    end

    test "returns type as-is for non-arrays" do
      assert Ash.Type.String == Introspection.get_inner_type(Ash.Type.String)
    end
  end

  describe "is_ash_type?/1" do
    test "returns true for Ash types" do
      assert Introspection.is_ash_type?(Ash.Type.String)
      assert Introspection.is_ash_type?(Ash.Type.Integer)
    end

    test "returns false for non-Ash types" do
      refute Introspection.is_ash_type?(String)
      refute Introspection.is_ash_type?(:string)
    end
  end

  describe "has_interop_field_names?/1" do
    test "returns true for modules with interop_field_names callback" do
      assert Introspection.has_interop_field_names?(AshIntrospection.Test.TaskStats)
    end

    test "returns false for modules without the callback" do
      refute Introspection.has_interop_field_names?(Ash.Type.String)
      refute Introspection.has_interop_field_names?(nil)
    end
  end

  describe "get_interop_field_names_map/1" do
    test "returns field names map for modules with callback" do
      map = Introspection.get_interop_field_names_map(AshIntrospection.Test.TaskStats)

      assert %{
               is_active?: "isActive",
               task_count: "taskCount",
               meta_1: "meta1"
             } == map
    end

    test "returns empty map for modules without callback" do
      assert %{} == Introspection.get_interop_field_names_map(Ash.Type.String)
      assert %{} == Introspection.get_interop_field_names_map(nil)
    end
  end

  describe "build_reverse_field_names_map/1" do
    test "builds reverse map from field names map" do
      field_names = %{is_active?: "isActive", meta_1: "meta1"}
      reverse = Introspection.build_reverse_field_names_map(field_names)

      assert %{"isActive" => :is_active?, "meta1" => :meta_1} == reverse
    end

    test "builds reverse map from module with callback" do
      reverse = Introspection.build_reverse_field_names_map(AshIntrospection.Test.TaskStats)

      assert %{
               "isActive" => :is_active?,
               "taskCount" => :task_count,
               "meta1" => :meta_1
             } == reverse
    end
  end

  describe "is_custom_interop_type?/1" do
    test "returns true for types with interop_type_name callback" do
      assert Introspection.is_custom_interop_type?(AshIntrospection.Test.CustomType)
    end

    test "returns false for types without callback" do
      refute Introspection.is_custom_interop_type?(Ash.Type.String)
    end
  end

  describe "get_interop_type_name/1" do
    test "returns type name for custom types" do
      assert "CustomString" ==
               Introspection.get_interop_type_name(AshIntrospection.Test.CustomType)
    end

    test "returns nil for non-custom types" do
      assert nil == Introspection.get_interop_type_name(Ash.Type.String)
    end
  end

  describe "is_resource_instance_of?/1" do
    test "returns true when instance_of is a resource" do
      assert Introspection.is_resource_instance_of?(
               instance_of: AshIntrospection.Test.User
             )
    end

    test "returns false when no instance_of" do
      refute Introspection.is_resource_instance_of?([])
    end

    test "returns false when instance_of is not a resource" do
      refute Introspection.is_resource_instance_of?(instance_of: String)
    end
  end

  describe "has_field_constraints?/1" do
    test "returns true when fields constraint exists and is not empty" do
      assert Introspection.has_field_constraints?(fields: [name: [type: :string]])
    end

    test "returns false when no fields constraint" do
      refute Introspection.has_field_constraints?([])
    end

    test "returns false when fields is empty" do
      refute Introspection.has_field_constraints?(fields: [])
    end
  end

  describe "get_field_spec_type/2" do
    test "returns type and constraints for existing field" do
      field_specs = [
        name: [type: :string, constraints: [max_length: 100]],
        age: [type: :integer]
      ]

      assert {:string, [max_length: 100]} ==
               Introspection.get_field_spec_type(field_specs, :name)

      assert {:integer, []} == Introspection.get_field_spec_type(field_specs, :age)
    end

    test "returns {nil, []} for unknown field" do
      field_specs = [name: [type: :string]]
      assert {nil, []} == Introspection.get_field_spec_type(field_specs, :unknown)
    end
  end

  describe "unwrap_new_type/3" do
    test "unwraps NewType with interop_field_names callback" do
      {unwrapped_type, constraints} =
        Introspection.unwrap_new_type(
          AshIntrospection.Test.TaskStats,
          [],
          :interop_field_names
        )

      assert Ash.Type.Map == unwrapped_type
      assert AshIntrospection.Test.TaskStats == Keyword.get(constraints, :instance_of)
    end

    test "unwraps NewType with function callback" do
      callback = fn module ->
        Code.ensure_loaded?(module) && function_exported?(module, :interop_field_names, 0)
      end

      {unwrapped_type, constraints} =
        Introspection.unwrap_new_type(
          AshIntrospection.Test.TaskStats,
          [],
          callback
        )

      assert Ash.Type.Map == unwrapped_type
      assert AshIntrospection.Test.TaskStats == Keyword.get(constraints, :instance_of)
    end

    test "returns type unchanged for non-NewType" do
      {type, constraints} = Introspection.unwrap_new_type(Ash.Type.String, [max_length: 50])

      assert Ash.Type.String == type
      assert [max_length: 50] == constraints
    end
  end
end
