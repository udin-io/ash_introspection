# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.FieldProcessing.AtomizerEnvelopeTest do
  @moduledoc """
  `Atomizer` keeps an envelope's own keys and leaves its query-option values
  to `FieldSelector` (#24).

  A `get_original_field_name` callback may return `nil` for a name the
  resource does not map; its type says so. Before #24 `Atomizer` turned every
  such key into `nil`, so `fields`, `filter` and `sort` collapsed into one
  `nil` key and all but one value was lost, and it resolved a filter's keys
  against the parent resource, not the relationship's destination.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.FieldProcessing.Atomizer
  alias AshIntrospection.Test.RelPagination.Library

  # The callback a consumer passes: the resource's own field names map, any
  # other name maps to `nil`.
  @config %{
    is_interop_resource?: &__MODULE__.interop?/1,
    get_original_field_name: &__MODULE__.original_name/2
  }

  def interop?(_resource), do: true

  def original_name(_resource, "books"), do: :books
  def original_name(_resource, "name"), do: :name
  def original_name(_resource, _name), do: nil

  test "a nil-returning callback keeps fields, filter and sort as distinct keys" do
    envelope = %{
      "fields" => ["title"],
      "filter" => %{"title" => %{"eq" => "b"}},
      "sort" => "-title"
    }

    assert [%{books: atomized}] =
             Atomizer.atomize_requested_fields([%{"books" => envelope}], Library, @config)

    assert Map.keys(atomized) |> Enum.sort() == ["fields", "filter", "sort"]
    assert atomized["sort"] == "-title"
  end

  test "a filter value's keys come back unchanged" do
    # `name` is a field of the parent, so treating the filter as a field
    # selection would turn it into `:name`.
    filter = %{"name" => %{"eq" => "b"}, "or" => [%{"title" => %{"eq" => "c"}}]}

    assert [%{books: %{"filter" => ^filter}}] =
             Atomizer.atomize_requested_fields(
               [%{"books" => %{"fields" => ["title"], "filter" => filter}}],
               Library,
               @config
             )
  end

  test "a page value comes back unchanged" do
    assert [%{books: %{"page" => %{"limit" => 1, "offset" => 2}}}] =
             Atomizer.atomize_requested_fields(
               [%{"books" => %{"fields" => ["title"], "page" => %{"limit" => 1, "offset" => 2}}}],
               Library,
               @config
             )
  end

  test "a name the callback maps to nil stays a string" do
    assert ["unmapped", :name] =
             Atomizer.atomize_requested_fields(["unmapped", "name"], Library, @config)
  end

  test "a nested key the callback maps to nil stays a string" do
    assert [%{"unmapped" => ["title"]}] =
             Atomizer.atomize_requested_fields([%{"unmapped" => ["title"]}], Library, @config)
  end

  defmodule NilInfo do
    @moduledoc false
    def interop_resource?(_resource), do: true
    def get_original_field_name(_resource, "name"), do: :name
    def get_original_field_name(_resource, _name), do: nil
  end

  test "a resource_info_module that maps a name to nil leaves it a string" do
    config = %{resource_info_module: NilInfo}

    assert ["unmapped", :name, %{"unmapped" => ["title"]}] =
             Atomizer.atomize_requested_fields(
               ["unmapped", "name", %{"unmapped" => ["title"]}],
               Library,
               config
             )
  end

  test "a nil-returning callback keeps args and fields" do
    assert [%{books: %{"args" => %{name: "x"}, "fields" => [:name]}}] =
             Atomizer.atomize_requested_fields(
               [%{"books" => %{"args" => %{"name" => "x"}, "fields" => ["name"]}}],
               Library,
               @config
             )
  end

  test "{args, fields} still atomizes as before" do
    assert [%{"self" => %{"args" => %{"prefix" => "test"}}}] =
             Atomizer.atomize_requested_fields([%{"self" => %{"args" => %{"prefix" => "test"}}}])
  end
end
