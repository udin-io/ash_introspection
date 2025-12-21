# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Codegen.ValidationErrorTypesTest do
  use ExUnit.Case, async: true

  alias AshIntrospection.Codegen.ValidationErrorTypes
  alias AshIntrospection.Test.{EmbeddedAddress, CustomType, Post, User}

  # ─────────────────────────────────────────────────────────────────
  # Basic Type Classification Tests
  # ─────────────────────────────────────────────────────────────────

  describe "classify_error_type/2 for primitives" do
    test "classifies nil as primitive errors" do
      assert {:ok, {:primitive_errors, nil}} = ValidationErrorTypes.classify_error_type(nil, [])
    end

    test "classifies string as primitive errors" do
      assert {:ok, {:primitive_errors, nil}} =
               ValidationErrorTypes.classify_error_type(:string, [])
    end

    test "classifies integer as primitive errors" do
      assert {:ok, {:primitive_errors, nil}} =
               ValidationErrorTypes.classify_error_type(:integer, [])
    end

    test "classifies boolean as primitive errors" do
      assert {:ok, {:primitive_errors, nil}} =
               ValidationErrorTypes.classify_error_type(:boolean, [])
    end

    test "classifies uuid as primitive errors" do
      assert {:ok, {:primitive_errors, nil}} = ValidationErrorTypes.classify_error_type(:uuid, [])
    end
  end

  describe "classify_error_type/2 for arrays" do
    test "classifies array of primitives" do
      assert {:ok, {:array_errors, {:primitive_errors, nil}}} =
               ValidationErrorTypes.classify_error_type({:array, :string}, [])
    end

    test "classifies array of embedded resources" do
      assert {:ok, {:array_errors, {:resource_errors, EmbeddedAddress}}} =
               ValidationErrorTypes.classify_error_type(
                 {:array, Ash.Type.Struct},
                 items: [instance_of: EmbeddedAddress]
               )
    end

    test "classifies nested arrays" do
      assert {:ok, {:array_errors, {:array_errors, {:primitive_errors, nil}}}} =
               ValidationErrorTypes.classify_error_type({:array, {:array, :string}}, [])
    end
  end

  describe "classify_error_type/2 for embedded resources" do
    test "classifies embedded resource via Ash.Type.Struct" do
      assert {:ok, {:resource_errors, EmbeddedAddress}} =
               ValidationErrorTypes.classify_error_type(
                 Ash.Type.Struct,
                 instance_of: EmbeddedAddress
               )
    end

    test "classifies embedded resource module directly" do
      assert {:ok, {:resource_errors, EmbeddedAddress}} =
               ValidationErrorTypes.classify_error_type(EmbeddedAddress, [])
    end
  end

  describe "classify_error_type/2 for custom types" do
    test "classifies custom type with interop_type_name" do
      assert {:ok, {:custom_type_errors, CustomType}} =
               ValidationErrorTypes.classify_error_type(CustomType, [])
    end
  end

  describe "classify_error_type/2 for typed containers" do
    test "classifies map with field constraints" do
      constraints = [
        fields: [
          name: [type: :string],
          age: [type: :integer]
        ]
      ]

      assert {:ok, {:typed_container_errors, field_classifications}} =
               ValidationErrorTypes.classify_error_type(Ash.Type.Map, constraints)

      assert {:name, {:primitive_errors, nil}} in field_classifications
      assert {:age, {:primitive_errors, nil}} in field_classifications
    end

    test "classifies map without field constraints as unconstrained" do
      assert {:ok, {:unconstrained_map_errors, nil}} =
               ValidationErrorTypes.classify_error_type(Ash.Type.Map, [])
    end

    test "classifies keyword with field constraints" do
      constraints = [
        fields: [
          key1: [type: :string],
          key2: [type: :boolean]
        ]
      ]

      assert {:ok, {:typed_container_errors, _}} =
               ValidationErrorTypes.classify_error_type(Ash.Type.Keyword, constraints)
    end

    test "classifies tuple with field constraints" do
      constraints = [
        fields: [
          first: [type: :string],
          second: [type: :integer]
        ]
      ]

      assert {:ok, {:typed_container_errors, _}} =
               ValidationErrorTypes.classify_error_type(Ash.Type.Tuple, constraints)
    end
  end

  describe "classify_error_type/2 for nested types" do
    test "classifies typed container with embedded resource field" do
      constraints = [
        fields: [
          name: [type: :string],
          address: [type: Ash.Type.Struct, constraints: [instance_of: EmbeddedAddress]]
        ]
      ]

      assert {:ok, {:typed_container_errors, field_classifications}} =
               ValidationErrorTypes.classify_error_type(Ash.Type.Map, constraints)

      assert {:name, {:primitive_errors, nil}} in field_classifications
      assert {:address, {:resource_errors, EmbeddedAddress}} in field_classifications
    end

    test "classifies typed container with array field" do
      constraints = [
        fields: [
          tags: [type: {:array, :string}]
        ]
      ]

      assert {:ok, {:typed_container_errors, field_classifications}} =
               ValidationErrorTypes.classify_error_type(Ash.Type.Map, constraints)

      assert {:tags, {:array_errors, {:primitive_errors, nil}}} in field_classifications
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Action Input Error Classification Tests
  # ─────────────────────────────────────────────────────────────────

  describe "classify_action_input_errors/2" do
    test "classifies create action inputs" do
      action = Ash.Resource.Info.action(Post, :create)
      classifications = ValidationErrorTypes.classify_action_input_errors(Post, action)

      # Should include accepted attributes
      field_names = Enum.map(classifications, fn {name, _, _} -> name end)
      assert :title in field_names
      assert :body in field_names
      assert :published in field_names

      # All should be primitive errors for this action
      Enum.each(classifications, fn {_name, classification, _field} ->
        assert {:primitive_errors, nil} = classification
      end)
    end

    test "classifies generic action with arguments" do
      action = Ash.Resource.Info.action(Post, :search)
      classifications = ValidationErrorTypes.classify_action_input_errors(Post, action)

      field_names = Enum.map(classifications, fn {name, _, _} -> name end)
      assert :query in field_names
      assert :limit in field_names
    end

    test "returns empty list for actions with no inputs" do
      action = Ash.Resource.Info.action(Post, :ping)
      assert [] = ValidationErrorTypes.classify_action_input_errors(Post, action)
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Resource Attribute Error Classification Tests
  # ─────────────────────────────────────────────────────────────────

  describe "classify_resource_attribute_errors/1" do
    test "classifies all public attributes of a resource" do
      classifications = ValidationErrorTypes.classify_resource_attribute_errors(EmbeddedAddress)

      field_names = Enum.map(classifications, fn {name, _, _} -> name end)
      assert :street in field_names
      assert :city in field_names
      assert :zip_code in field_names

      # All should be primitive errors for this simple resource
      Enum.each(classifications, fn {_name, classification, _attr} ->
        assert {:primitive_errors, nil} = classification
      end)
    end

    test "classifies user attributes with different types" do
      classifications = ValidationErrorTypes.classify_resource_attribute_errors(User)

      # Find the metadata field which is a map
      metadata = Enum.find(classifications, fn {name, _, _} -> name == :metadata end)
      assert {_, {:unconstrained_map_errors, nil}, _} = metadata
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Field Error Classification Tests
  # ─────────────────────────────────────────────────────────────────

  describe "classify_field_errors/1" do
    test "classifies simple field list" do
      fields = [
        name: [type: :string],
        age: [type: :integer],
        active: [type: :boolean]
      ]

      classifications = ValidationErrorTypes.classify_field_errors(fields)

      assert {:name, {:primitive_errors, nil}} in classifications
      assert {:age, {:primitive_errors, nil}} in classifications
      assert {:active, {:primitive_errors, nil}} in classifications
    end

    test "classifies nested field types" do
      fields = [
        address: [type: Ash.Type.Struct, constraints: [instance_of: EmbeddedAddress]],
        tags: [type: {:array, :string}]
      ]

      classifications = ValidationErrorTypes.classify_field_errors(fields)

      assert {:address, {:resource_errors, EmbeddedAddress}} in classifications
      assert {:tags, {:array_errors, {:primitive_errors, nil}}} in classifications
    end
  end
end
