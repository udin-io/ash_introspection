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
    Macro.camelize(snake)
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
    case Macro.camelize(snake) do
      <<first::utf8, rest::binary>> -> String.downcase(<<first::utf8>>) <> rest
      "" -> ""
    end
  end

  @doc """
  Converts a camelCase string or atom to snake_case.

  ## Examples

      iex> AshIntrospection.Helpers.camel_to_snake_case("userName")
      "user_name"

      iex> AshIntrospection.Helpers.camel_to_snake_case(:userName)
      "user_name"
  """
  def camel_to_snake_case(camel) when is_binary(camel) do
    Macro.underscore(camel)
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
    Macro.underscore(pascal)
  end
end
