# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.ErrorFormatterTest do
  @moduledoc """
  An error map is a template: `message`, `short_message` and the strings under
  `details` carry `%{name}` placeholders and `vars` carries the values, so the
  client interpolates and can localize.

  Formatting only the dictionary keys breaks that contract — `%{action_name}`
  cannot resolve against a `vars` entry that arrived as `actionName`. These
  tests assert the placeholder and the key it names always agree.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.ErrorFormatter

  describe "placeholders and vars keys" do
    test "renames a multi-word placeholder alongside its var" do
      formatted =
        ErrorFormatter.format(
          %{
            message: "RPC action %{action_name} not found",
            vars: %{action_name: "get_todo"}
          },
          :camel_case
        )

      assert formatted["message"] == "RPC action %{actionName} not found"
      assert formatted["vars"] == %{"actionName" => "get_todo"}
    end

    test "every placeholder still names a key in vars" do
      formatted =
        ErrorFormatter.format(
          %{
            message: "Unexpected fields %{extra_fields}. Allowed: %{allowed_fields}",
            short_message: "Unexpected %{extra_fields}",
            vars: %{extra_fields: "colour", allowed_fields: "color, size"},
            fields: [],
            path: []
          },
          :camel_case
        )

      assert placeholders(formatted["message"]) == ["allowedFields", "extraFields"]
      assert placeholders(formatted["shortMessage"]) == ["extraFields"]

      for name <- placeholders(formatted["message"]) do
        assert Map.has_key?(formatted["vars"], name)
      end
    end

    test "rewrites placeholders inside details strings" do
      formatted =
        ErrorFormatter.format(
          %{
            message: "Unexpected getBy fields",
            vars: %{allowed_fields: "id, email"},
            details: %{suggestion: "Only provide the allowed getBy fields: %{allowed_fields}"}
          },
          :camel_case
        )

      assert formatted["details"]["suggestion"] ==
               "Only provide the allowed getBy fields: %{allowedFields}"
    end

    test "resolves a placeholder that names a details key" do
      formatted =
        ErrorFormatter.format(
          %{
            message: "Field is %{field_type}",
            vars: %{},
            details: %{field_type: "union", hint: "check %{field_type}"}
          },
          :camel_case
        )

      assert formatted["message"] == "Field is %{fieldType}"
      assert formatted["details"]["hint"] == "check %{fieldType}"
      assert Map.has_key?(formatted["details"], "fieldType")
    end

    test "leaves a placeholder no dictionary names alone" do
      formatted =
        ErrorFormatter.format(
          %{message: "Field %{unknown_name} is odd", vars: %{field: "email"}},
          :camel_case
        )

      assert formatted["message"] == "Field %{unknown_name} is odd"
    end

    test "leaves a single-word placeholder alone" do
      formatted =
        ErrorFormatter.format(
          %{message: "Field %{field} is required", vars: %{field: "email"}},
          :camel_case
        )

      assert formatted["message"] == "Field %{field} is required"
      assert formatted["vars"] == %{"field" => "email"}
    end

    test "rewrites in a single pass, so a renamed placeholder is never renamed again" do
      formatted =
        ErrorFormatter.format(
          %{
            message: "%{action_name} and %{actionName}",
            vars: %{action_name: "get_todo", actionName: "already_formatted"}
          },
          :camel_case
        )

      assert formatted["message"] == "%{actionName} and %{actionName}"
    end

    test "treats a var value as data, not as a template" do
      formatted =
        ErrorFormatter.format(
          %{
            message: "Field %{field_type} is odd",
            vars: %{field_type: "literally %{field_type}"}
          },
          :camel_case
        )

      assert formatted["vars"] == %{"fieldType" => "literally %{field_type}"}
    end
  end

  describe "field name formatting" do
    test "formats every top-level key" do
      formatted =
        ErrorFormatter.format(
          %{type: "not_found", short_message: "Not found", error_id: "abc"},
          :camel_case
        )

      assert formatted |> Map.keys() |> Enum.sort() == ["errorId", "shortMessage", "type"]
    end

    test "honours the snake_case formatter by leaving names alone" do
      error = %{message: "RPC action %{action_name} not found", vars: %{action_name: "get_todo"}}

      formatted = ErrorFormatter.format(error, :snake_case)

      assert formatted["message"] == "RPC action %{action_name} not found"
      assert formatted["vars"] == %{"action_name" => "get_todo"}
    end

    test "formats a list under fields without touching its values" do
      formatted =
        ErrorFormatter.format(%{fields: ["user_name"], path: ["nested_field"]}, :camel_case)

      assert formatted["fields"] == ["user_name"]
      assert formatted["path"] == ["nested_field"]
    end
  end

  describe "non-map input" do
    test "passes a string through untouched" do
      assert ErrorFormatter.format("something went wrong", :camel_case) ==
               "something went wrong"
    end

    test "passes a struct through untouched" do
      error = %ArgumentError{message: "bad"}

      assert ErrorFormatter.format(error, :camel_case) == error
    end
  end

  defp placeholders(string) do
    ~r/%\{([^}]+)\}/
    |> Regex.scan(string)
    |> Enum.map(fn [_full, name] -> name end)
    |> Enum.sort()
  end
end
