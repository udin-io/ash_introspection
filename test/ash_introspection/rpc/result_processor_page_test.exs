# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.ResultProcessorPageTest do
  @moduledoc """
  The page map stage 3 builds from an offset page and from a keyset page.
  Before #24 only the offset shape had a test; the keyset clause, cursors
  included, had none.
  """
  use ExUnit.Case, async: true

  require Ash.Query

  alias AshIntrospection.Rpc.ResultProcessor
  alias AshIntrospection.Test.RelPagination.Book

  setup do
    for title <- ["a", "b", "c"] do
      Book |> Ash.Changeset.for_create(:create, %{title: title}) |> Ash.create!()
    end

    :ok
  end

  test "a keyset page carries its records, cursors and type" do
    page =
      Book
      |> Ash.Query.for_read(:list_keyset)
      |> Ash.Query.sort(:title)
      |> Ash.read!(page: [limit: 2])

    assert %{
             results: [%{title: "a"}, %{title: "b"}],
             has_more: true,
             limit: 2,
             type: :keyset,
             previous_page: previous_page,
             next_page: next_page
           } = ResultProcessor.process(page, [:title], Book, %{})

    assert previous_page == hd(page.results).__metadata__.keyset
    assert next_page == List.last(page.results).__metadata__.keyset
  end

  test "an empty keyset page has no cursors" do
    page =
      Book
      |> Ash.Query.for_read(:list_keyset)
      |> Ash.Query.filter(title == "none")
      |> Ash.read!(page: [limit: 2])

    assert %{results: [], previous_page: nil, next_page: nil, has_more: false} =
             ResultProcessor.process(page, [:title], Book, %{})
  end

  test "an offset page carries its records, position and type" do
    page = Book |> Ash.Query.sort(:title) |> Ash.read!(page: [limit: 1, offset: 1])

    assert %{results: [%{title: "b"}], has_more: true, limit: 1, offset: 1, type: :offset} =
             ResultProcessor.process(page, [:title], Book, %{})
  end
end
