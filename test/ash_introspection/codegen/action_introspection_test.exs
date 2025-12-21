# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Codegen.ActionIntrospectionTest do
  use ExUnit.Case, async: true

  alias AshIntrospection.Codegen.ActionIntrospection
  alias AshIntrospection.Test.Post

  # Helper to get action from resource
  defp get_action(action_name) do
    Ash.Resource.Info.action(Post, action_name)
  end

  # ─────────────────────────────────────────────────────────────────
  # Pagination Tests
  # ─────────────────────────────────────────────────────────────────

  describe "action_supports_pagination?/1" do
    test "returns true for read actions with pagination config" do
      assert ActionIntrospection.action_supports_pagination?(get_action(:list_offset))
      assert ActionIntrospection.action_supports_pagination?(get_action(:list_keyset))
      assert ActionIntrospection.action_supports_pagination?(get_action(:list_required))
      assert ActionIntrospection.action_supports_pagination?(get_action(:list_hybrid))
    end

    test "returns false for read actions without pagination" do
      refute ActionIntrospection.action_supports_pagination?(get_action(:read))
    end

    test "returns false for get actions even with arguments" do
      refute ActionIntrospection.action_supports_pagination?(get_action(:get_by_id))
    end

    test "returns false for non-read actions" do
      refute ActionIntrospection.action_supports_pagination?(get_action(:create))
      refute ActionIntrospection.action_supports_pagination?(get_action(:update))
      refute ActionIntrospection.action_supports_pagination?(get_action(:destroy))
    end
  end

  describe "action_supports_offset_pagination?/1" do
    test "returns true for offset-enabled actions" do
      assert ActionIntrospection.action_supports_offset_pagination?(get_action(:list_offset))
      assert ActionIntrospection.action_supports_offset_pagination?(get_action(:list_required))
      assert ActionIntrospection.action_supports_offset_pagination?(get_action(:list_hybrid))
    end

    test "returns false for keyset-only actions" do
      refute ActionIntrospection.action_supports_offset_pagination?(get_action(:list_keyset))
    end

    test "returns false for non-paginated actions" do
      refute ActionIntrospection.action_supports_offset_pagination?(get_action(:read))
    end
  end

  describe "action_supports_keyset_pagination?/1" do
    test "returns true for keyset-enabled actions" do
      assert ActionIntrospection.action_supports_keyset_pagination?(get_action(:list_keyset))
      assert ActionIntrospection.action_supports_keyset_pagination?(get_action(:list_hybrid))
    end

    test "returns false for offset-only actions" do
      refute ActionIntrospection.action_supports_keyset_pagination?(get_action(:list_offset))
    end

    test "returns false for non-paginated actions" do
      refute ActionIntrospection.action_supports_keyset_pagination?(get_action(:read))
    end
  end

  describe "action_requires_pagination?/1" do
    test "returns true for required pagination actions" do
      # Ash defaults required? to true for pagination
      assert ActionIntrospection.action_requires_pagination?(get_action(:list_required))
      assert ActionIntrospection.action_requires_pagination?(get_action(:list_offset))
      assert ActionIntrospection.action_requires_pagination?(get_action(:list_keyset))
    end

    test "returns false for non-paginated actions" do
      refute ActionIntrospection.action_requires_pagination?(get_action(:read))
    end
  end

  describe "action_supports_countable?/1" do
    test "returns true for countable actions" do
      # Ash defaults countable to true for pagination
      assert ActionIntrospection.action_supports_countable?(get_action(:list_offset))
      assert ActionIntrospection.action_supports_countable?(get_action(:list_keyset))
    end

    test "returns false for non-paginated actions" do
      refute ActionIntrospection.action_supports_countable?(get_action(:read))
    end
  end

  describe "action_has_default_limit?/1" do
    test "returns true for actions with default limit" do
      assert ActionIntrospection.action_has_default_limit?(get_action(:list_offset))
      assert ActionIntrospection.action_has_default_limit?(get_action(:list_keyset))
    end

    test "returns false for actions without default limit" do
      refute ActionIntrospection.action_has_default_limit?(get_action(:read))
    end
  end

  describe "get_default_limit/1" do
    test "returns the default limit for paginated actions" do
      assert ActionIntrospection.get_default_limit(get_action(:list_offset)) == 10
      assert ActionIntrospection.get_default_limit(get_action(:list_keyset)) == 20
      assert ActionIntrospection.get_default_limit(get_action(:list_required)) == 25
      assert ActionIntrospection.get_default_limit(get_action(:list_hybrid)) == 15
    end

    test "returns nil for non-paginated actions" do
      assert ActionIntrospection.get_default_limit(get_action(:read)) == nil
    end
  end

  describe "get_max_page_size/1" do
    test "returns the max page size when configured" do
      assert ActionIntrospection.get_max_page_size(get_action(:list_offset)) == 100
    end

    test "returns default max page size when not explicitly configured" do
      # Ash defaults max_page_size to 250
      assert ActionIntrospection.get_max_page_size(get_action(:list_keyset)) == 250
    end

    test "returns nil for non-paginated actions" do
      assert ActionIntrospection.get_max_page_size(get_action(:read)) == nil
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Input Type Tests
  # ─────────────────────────────────────────────────────────────────

  describe "action_input_type/2" do
    test "returns :required for actions with required input" do
      # create accepts title which has allow_nil?: false
      assert ActionIntrospection.action_input_type(Post, get_action(:create)) == :required
      # create_draft also accepts title which has allow_nil?: false
      assert ActionIntrospection.action_input_type(Post, get_action(:create_draft)) == :required
      # search has required query argument
      assert ActionIntrospection.action_input_type(Post, get_action(:search)) == :required
    end

    test "returns :optional for actions with only optional input" do
      # get_popular only has optional limit argument with a default
      assert ActionIntrospection.action_input_type(Post, get_action(:get_popular)) == :optional
    end

    test "returns :none for actions with no input" do
      assert ActionIntrospection.action_input_type(Post, get_action(:ping)) == :none
      assert ActionIntrospection.action_input_type(Post, get_action(:get_stats)) == :none
    end
  end

  describe "get_required_inputs/2" do
    test "returns required field names for create actions" do
      required = ActionIntrospection.get_required_inputs(Post, get_action(:create))
      assert :title in required
    end

    test "returns required argument names for generic actions" do
      required = ActionIntrospection.get_required_inputs(Post, get_action(:search))
      assert :query in required
      refute :limit in required
    end

    test "returns empty list for actions with no required inputs" do
      assert ActionIntrospection.get_required_inputs(Post, get_action(:ping)) == []
    end
  end

  describe "get_optional_inputs/2" do
    test "returns optional field names" do
      optional = ActionIntrospection.get_optional_inputs(Post, get_action(:create))
      assert :body in optional
      assert :published in optional
    end

    test "returns optional argument names" do
      optional = ActionIntrospection.get_optional_inputs(Post, get_action(:search))
      assert :limit in optional
      refute :query in optional
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Return Type Tests
  # ─────────────────────────────────────────────────────────────────

  describe "action_returns_field_selectable_type?/1" do
    test "returns error for non-generic actions" do
      assert {:error, :not_generic_action} =
               ActionIntrospection.action_returns_field_selectable_type?(get_action(:read))

      assert {:error, :not_generic_action} =
               ActionIntrospection.action_returns_field_selectable_type?(get_action(:create))
    end

    test "returns resource type for single resource return" do
      assert {:ok, :resource, Post} =
               ActionIntrospection.action_returns_field_selectable_type?(get_action(:get_featured))
    end

    test "returns array_of_resource for array of resources" do
      assert {:ok, :array_of_resource, Post} =
               ActionIntrospection.action_returns_field_selectable_type?(get_action(:get_popular))
    end

    test "returns typed_map for map with field constraints" do
      result = ActionIntrospection.action_returns_field_selectable_type?(get_action(:get_stats))
      assert {:ok, :typed_map, fields} = result
      assert Keyword.has_key?(fields, :total_posts)
      assert Keyword.has_key?(fields, :published_count)
      assert Keyword.has_key?(fields, :draft_count)
    end

    test "returns unconstrained_map for map without field constraints" do
      assert {:ok, :unconstrained_map, nil} =
               ActionIntrospection.action_returns_field_selectable_type?(get_action(:get_metadata))
    end

    test "returns error for primitive return types" do
      assert {:error, :not_field_selectable_type} =
               ActionIntrospection.action_returns_field_selectable_type?(get_action(:get_count))

      assert {:error, :not_field_selectable_type} =
               ActionIntrospection.action_returns_field_selectable_type?(get_action(:ping))
    end
  end

  describe "action_supports_field_selection?/1" do
    test "returns true for field-selectable returns" do
      assert ActionIntrospection.action_supports_field_selection?(get_action(:get_featured))
      assert ActionIntrospection.action_supports_field_selection?(get_action(:get_popular))
      assert ActionIntrospection.action_supports_field_selection?(get_action(:get_stats))
    end

    test "returns false for primitive returns" do
      refute ActionIntrospection.action_supports_field_selection?(get_action(:get_count))
      refute ActionIntrospection.action_supports_field_selection?(get_action(:ping))
    end

    test "returns false for non-generic actions" do
      refute ActionIntrospection.action_supports_field_selection?(get_action(:read))
    end
  end
end
