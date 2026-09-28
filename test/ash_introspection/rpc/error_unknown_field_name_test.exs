# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.ErrorUnknownFieldNameTest do
  @moduledoc """
  An unknown field is named the way the client sent it (#113). Before, the
  selector threw the parsed name and `ErrorBuilder` ran it through the output
  formatter, so `books.nope_field` answered `books.nopeField`: a field the
  client never sent.

  Every row sends `inserted_at`, a snake_case name that no fixture here has but
  that exists as an atom, so the selector resolves it to that atom. That is
  the case a "keep a string, format an atom" shortcut gets wrong. One row per
  selection path, because each path resolves names on its own.

  Two throw sites fire for a relationship that exists but whose destination is
  outside the interop set. Their rows send the relationship's snake_case name.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.ErrorBuilder
  alias AshIntrospection.Rpc.FieldProcessing.FieldSelector
  alias AshIntrospection.Test.LoadThrough
  alias AshIntrospection.Test.ManifestFixture
  alias AshIntrospection.Test.Post
  alias AshIntrospection.Test.RelPagination.Library
  alias AshIntrospection.Test.Shelf
  alias AshIntrospection.Test.User

  # Pins the atom, so the rows do not depend on Ash defining it.
  @existing_atom :inserted_at
  @name Atom.to_string(@existing_atom)

  for {label, resource, action, fields, type, expected} <- [
        {"resource field", User, :read, [@name], "unknown_field", @name},
        {"resource field with nested fields", User, :read, [%{@name => ["id"]}], "unknown_field",
         @name},
        {"resource calculation with args", User, :read, [%{@name => %{"args" => %{}}}],
         "unknown_field", @name},
        {"embedded resource field", User, :read, [%{"address" => [@name]}], "unknown_field",
         "address.#{@name}"},
        {"relationship field", Library, :read, [%{"books" => [@name]}], "unknown_field",
         "books.#{@name}"},
        {"typed map field", Post, :get_stats, [@name], "unknown_map_field", @name},
        {"typed map field with nested fields", Post, :get_stats, [%{@name => ["x"]}],
         "unknown_map_field", @name},
        {"typed map field in a multi-entry map", Post, :get_stats,
         [%{@name => ["x"], "totalPosts" => ["y"]}], "unknown_map_field", @name},
        {"typed struct field", Post, :get_task_stats, [@name], "unknown_field", @name},
        {"typed struct field with nested fields", Post, :get_task_stats, [%{@name => ["x"]}],
         "unknown_field", @name},
        {"tuple field", Post, :get_bounds, [@name], "unknown_field", @name},
        {"tuple field with nested fields", Post, :get_bounds, [%{@name => ["x"]}],
         "unknown_field", @name},
        {"tuple field in a multi-entry map", Post, :get_bounds,
         [%{@name => ["x"], "latitude" => ["y"]}], "unknown_field", @name},
        {"field below an aggregate", LoadThrough.Owner, :read, [%{"firstTag" => [@name]}],
         "unknown_field", "firstTag.#{@name}"},
        {"union member", Shelf, :read, [%{"content" => [@name]}], "unknown_union_field",
         "content.#{@name}"},
        {"union member with nested fields", Shelf, :read, [%{"content" => [%{@name => ["x"]}]}],
         "unknown_union_field", "content.#{@name}"}
      ] do
    test "#{label}: names the field as sent" do
      response = unknown!(unquote(resource), unquote(action), unquote(Macro.escape(fields)))

      assert response["type"] == unquote(type)
      assert response["fields"] == [unquote(expected)]
      assert response["vars"]["field"] == unquote(expected)
    end
  end

  describe "a relationship field" do
    test "a name no atom has is named as sent" do
      response = unknown!(Library, :read, [%{"books" => ["nope_field"]}])

      assert response["fields"] == ["books.nope_field"]
      assert response["vars"] == %{"field" => "books.nope_field"}
      assert response["message"] == "Unknown field %{field}"
    end

    test "a camelCase name is named as sent" do
      response = unknown!(Library, :read, [%{"books" => ["nopeField"]}])

      assert response["fields"] == ["books.nopeField"]
    end

    test "path segments stay formatted" do
      response = unknown!(Library, :read, [%{"sealed_books" => [@name]}])

      assert response["fields"] == ["sealedBooks.#{@name}"]
      assert response["path"] == ["sealedBooks"]
    end
  end

  describe "a relationship to a resource outside the interop set" do
    test "is named as sent" do
      response = unknown!(Library, :read, [%{"sealed_books" => ["title"]}], book_hidden())

      assert response["fields"] == ["sealed_books"]
    end

    test "is named as sent through a query envelope" do
      response =
        unknown!(
          Library,
          :read,
          [%{"found_books" => %{"fields" => ["title"], "sort" => "title"}}],
          book_hidden()
        )

      assert response["fields"] == ["found_books"]
    end
  end

  describe "a duplicate field" do
    # Carries the parsed name, not the one the client sent, so it stays
    # formatted: `fooBarZz` parses to a string `foo_bar_zz`, which no atom has.
    test "is named formatted" do
      assert {:error, error} =
               FieldSelector.process(
                 User,
                 :read,
                 ["fooBarZz", "fooBarZz"],
                 ManifestFixture.decorated_config()
               )

      response = ErrorBuilder.build_error_response(error)

      assert response.type == "duplicate_field"
      assert response.fields == ["fooBarZz"]
    end
  end

  describe "an Elixir caller" do
    test "an atom name is formatted" do
      response = unknown!(User, :read, [:inserted_at])

      assert response["fields"] == ["insertedAt"]
    end
  end

  defp book_hidden, do: %{is_interop_resource?: &(&1 != AshIntrospection.Test.RelPagination.Book)}

  defp unknown!(resource, action, fields, extra \\ %{}) do
    config = ManifestFixture.decorated_config(extra)

    assert {:error, error} = FieldSelector.process(resource, action, fields, config)

    response = error |> ErrorBuilder.build_error_response() |> Jason.encode!() |> Jason.decode!()

    assert response["type"] in ["unknown_field", "unknown_map_field", "unknown_union_field"]
    response
  end
end
