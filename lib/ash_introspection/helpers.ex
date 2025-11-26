# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Helpers do
  @moduledoc """
  Utility functions for string manipulation and case transformations.

  Provides functions for converting between different naming conventions:
  - snake_case (Elixir/Ruby style)
  - camelCase (JavaScript/TypeScript style)
  - PascalCase (C#/Java class naming style)
  """

  @doc """
  Converts a snake_case string or atom to PascalCase.

  ## Examples

      iex> AshIntrospection.Helpers.snake_to_pascal_case(:user_name)
      "UserName"

      iex> AshIntrospection.Helpers.snake_to_pascal_case("user_name")
      "UserName"
  """
  def snake_to_pascal_case(snake) when is_atom(snake) do
    snake
    |> Atom.to_string()
    |> snake_to_pascal_case()
  end

  def snake_to_pascal_case(snake) when is_binary(snake) do
    snake
    |> String.split("_")
    |> Enum.with_index()
    |> Enum.map_join(fn {part, _} -> String.capitalize(part) end)
  end

  @doc """
  Converts a snake_case string or atom to camelCase.

  ## Examples

      iex> AshIntrospection.Helpers.snake_to_camel_case(:user_name)
      "userName"

      iex> AshIntrospection.Helpers.snake_to_camel_case("user_name")
      "userName"
  """
  def snake_to_camel_case(snake) when is_atom(snake) do
    snake
    |> Atom.to_string()
    |> snake_to_camel_case()
  end

  def snake_to_camel_case(snake) when is_binary(snake) do
    snake
    |> String.split("_")
    |> Enum.with_index()
    |> Enum.map_join(fn
      {part, 0} -> String.downcase(part)
      {part, _} -> String.capitalize(part)
    end)
  end

  @doc """
  Converts a camelCase string or atom to snake_case.

  Handles:
  - Standard camelCase (e.g., "userName" -> "user_name")
  - Mixed case with numbers (e.g., "user1Name" -> "user_1_name")

  ## Examples

      iex> AshIntrospection.Helpers.camel_to_snake_case("userName")
      "user_name"

      iex> AshIntrospection.Helpers.camel_to_snake_case(:userName)
      "user_name"
  """
  def camel_to_snake_case(camel) when is_binary(camel) do
    camel
    # 1. lowercase/digit to uppercase: aB, 1B -> a_B, 1_B
    |> String.replace(~r/([a-z\d])([A-Z])/, "\\1_\\2")
    # 2. lowercase to digits: a123 -> a_123
    |> String.replace(~r/([a-z])(\d+)/, "\\1_\\2")
    # 3. digits to lowercase: 123a -> 123_a
    |> String.replace(~r/(\d+)([a-z])/, "\\1_\\2")
    # 4. digits to uppercase: 123A -> 123_A
    |> String.replace(~r/(\d+)([A-Z])/, "\\1_\\2")
    # 5. uppercase to digits: A123 -> A_123
    |> String.replace(~r/([A-Z])(\d+)/, "\\1_\\2")
    |> String.downcase()
  end

  def camel_to_snake_case(camel) when is_atom(camel) do
    camel
    |> Atom.to_string()
    |> camel_to_snake_case()
  end

  @doc """
  Converts a PascalCase string or atom to snake_case.

  ## Examples

      iex> AshIntrospection.Helpers.pascal_to_snake_case("UserName")
      "user_name"

      iex> AshIntrospection.Helpers.pascal_to_snake_case(:UserName)
      "user_name"
  """
  def pascal_to_snake_case(pascal) when is_atom(pascal) do
    pascal
    |> Atom.to_string()
    |> pascal_to_snake_case()
  end

  def pascal_to_snake_case(pascal) when is_binary(pascal) do
    pascal
    # 1. lowercase to uppercase: a123 -> a_123
    |> String.replace(~r/([a-z\d])([A-Z])/, "\\1_\\2")
    # 2. lowercase to digits: a123 -> a_123
    |> String.replace(~r/([a-z])(\d+)/, "\\1_\\2")
    # 3. digits to lowercase: 123a -> 123_a
    |> String.replace(~r/(\d+)([a-z])/, "\\1_\\2")
    # 4. digits to uppercase: 123A -> 123_A
    |> String.replace(~r/(\d+)([A-Z])/, "\\1_\\2")
    # 5. uppercase to digits: A123 -> A_123
    |> String.replace(~r/([A-Z])(\d+)/, "\\1_\\2")
    |> String.downcase()
    |> String.trim_leading("_")
  end
end
