# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.FieldFormatterTest do
  use ExUnit.Case, async: true

  alias AshIntrospection.FieldFormatter

  describe "format_field/2" do
    test "formats field to camelCase" do
      assert "userName" == FieldFormatter.format_field(:user_name, :camel_case)
      assert "userName" == FieldFormatter.format_field("user_name", :camel_case)
    end

    test "formats field to PascalCase" do
      assert "UserName" == FieldFormatter.format_field(:user_name, :pascal_case)
      assert "UserName" == FieldFormatter.format_field("user_name", :pascal_case)
    end

    test "formats field to snake_case" do
      assert "user_name" == FieldFormatter.format_field(:user_name, :snake_case)
      assert "user_name" == FieldFormatter.format_field("user_name", :snake_case)
    end
  end

  describe "parse_input_field/2" do
    test "parses camelCase to internal atom" do
      assert :user_name == FieldFormatter.parse_input_field("userName", :camel_case)
    end

    test "parses PascalCase to internal atom" do
      assert :user_name == FieldFormatter.parse_input_field("UserName", :pascal_case)
    end

    test "parses snake_case to internal atom" do
      assert :user_name == FieldFormatter.parse_input_field("user_name", :snake_case)
    end
  end

  describe "format_fields/2" do
    test "formats all fields in a map" do
      input = %{user_name: "John", is_active: true}
      expected = %{"userName" => "John", "isActive" => true}

      assert expected == FieldFormatter.format_fields(input, :camel_case)
    end
  end

  describe "parse_input_fields/2" do
    test "parses all fields from client format" do
      input = %{"userName" => "John", "isActive" => true}
      expected = %{user_name: "John", is_active: true}

      assert expected == FieldFormatter.parse_input_fields(input, :camel_case)
    end
  end

  describe "format_field_name/2" do
    test "formats string field names" do
      assert "userName" == FieldFormatter.format_field_name("user_name", :camel_case)
      assert "UserName" == FieldFormatter.format_field_name("user_name", :pascal_case)
      assert "user_name" == FieldFormatter.format_field_name("user_name", :snake_case)
    end

    test "formats atom field names" do
      assert "userName" == FieldFormatter.format_field_name(:user_name, :camel_case)
    end
  end
end
