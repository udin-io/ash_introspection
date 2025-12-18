# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.HelpersTest do
  use ExUnit.Case, async: true

  alias AshIntrospection.Helpers

  describe "snake_to_pascal_case/1" do
    test "converts snake_case to PascalCase" do
      assert "UserName" == Helpers.snake_to_pascal_case("user_name")
      assert "IsActive" == Helpers.snake_to_pascal_case("is_active")
      assert "Id" == Helpers.snake_to_pascal_case("id")
    end

    test "handles numbers" do
      assert "Meta1" == Helpers.snake_to_pascal_case("meta_1")
      assert "User1Name" == Helpers.snake_to_pascal_case("user_1_name")
    end
  end

  describe "snake_to_camel_case/1" do
    test "converts snake_case to camelCase" do
      assert "userName" == Helpers.snake_to_camel_case("user_name")
      assert "isActive" == Helpers.snake_to_camel_case("is_active")
      assert "id" == Helpers.snake_to_camel_case("id")
    end

    test "handles numbers" do
      assert "meta1" == Helpers.snake_to_camel_case("meta_1")
      assert "user1Name" == Helpers.snake_to_camel_case("user_1_name")
    end
  end

  describe "camel_to_snake_case/1" do
    test "converts camelCase to snake_case" do
      assert "user_name" == Helpers.camel_to_snake_case("userName")
      assert "is_active" == Helpers.camel_to_snake_case("isActive")
      assert "id" == Helpers.camel_to_snake_case("id")
    end

    test "handles numbers" do
      assert "meta_1" == Helpers.camel_to_snake_case("meta1")
      assert "user_1_name" == Helpers.camel_to_snake_case("user1Name")
    end
  end

  describe "pascal_to_snake_case/1" do
    test "converts PascalCase to snake_case" do
      assert "user_name" == Helpers.pascal_to_snake_case("UserName")
      assert "is_active" == Helpers.pascal_to_snake_case("IsActive")
      assert "id" == Helpers.pascal_to_snake_case("Id")
    end
  end
end
