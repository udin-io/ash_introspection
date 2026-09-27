# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineRelationshipQueryTest do
  @moduledoc """
  A relationship in a field selection takes a query envelope - `filter`,
  `sort`, `page`, or bare `limit`/`offset` beside `fields` - at any depth
  (#24). Before #24 every envelope failed as `unknown_field` on a relationship
  that exists, or as `unsupported_field_combination`.

  Each test drives `FieldSelector.process/4` and all three `Pipeline` stages,
  then round-trips the response through `Jason`, so it asserts what the
  client receives.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.ErrorBuilder
  alias AshIntrospection.Rpc.FieldProcessing.FieldSelector
  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.LoadRestrictions
  alias AshIntrospection.Test.ManifestFixture
  alias AshIntrospection.Test.RelPagination

  setup do
    library = create!(RelPagination.Library, %{name: "Main"})

    for title <- ["a", "b", "c"] do
      create!(RelPagination.Book, %{title: title, library_id: library.id})
    end

    for body <- ["n1", "n2", "n3"] do
      create!(RelPagination.Note, %{body: body, library_id: library.id})
    end

    :ok
  end

  describe "a relationship query envelope" do
    test "filter returns only the matching related records" do
      assert {:ok, [%{"books" => [%{"title" => "b"}]}]} =
               rpc([
                 %{"books" => %{"fields" => ["title"], "filter" => %{"title" => %{"eq" => "b"}}}}
               ])
    end

    test "sort orders the related records" do
      assert {:ok, [%{"books" => books}]} =
               rpc([%{"books" => %{"fields" => ["title"], "sort" => "-title"}}])

      assert books == [%{"title" => "c"}, %{"title" => "b"}, %{"title" => "a"}]
    end

    test "bare limit on a relationship whose read does not require pagination is a plain slice" do
      assert {:ok, [%{"notes" => notes}]} =
               rpc([%{"notes" => %{"fields" => ["body"], "limit" => 2}}])

      assert length(notes) == 2
      assert Enum.all?(notes, &(Map.keys(&1) == ["body"]))
    end

    test "filter and sort keys resolve against the destination's client names" do
      assert {:ok, [%{"books" => books}]} =
               rpc([
                 %{
                   "books" => %{
                     "fields" => ["title"],
                     "filter" => %{"libraryId" => %{"isNil" => false}},
                     "sort" => "libraryId,-title"
                   }
                 }
               ])

      assert books == [%{"title" => "c"}, %{"title" => "b"}, %{"title" => "a"}]
    end

    # A consumer's name mapping differs per resource. Before #24 the filter's
    # keys were resolved against the parent, so `label` became Library's
    # `name`, a field Book does not have.
    test "filter keys resolve through the destination's name mapping, not the parent's" do
      labels = fn
        RelPagination.Library, "label" -> :name
        RelPagination.Book, "label" -> :title
        _resource, name when is_atom(name) -> name
        _resource, _name -> nil
      end

      assert {:ok, [%{"books" => [%{"title" => "b"}]}]} =
               rpc(
                 [
                   %{
                     "books" => %{"fields" => ["title"], "filter" => %{"label" => %{"eq" => "b"}}}
                   }
                 ],
                 %{get_original_field_name: labels}
               )
    end

    test "a bare fields envelope returns the same as the plain nested list" do
      assert {:ok, plain} = rpc([%{"books" => ["title"]}])
      assert {:ok, ^plain} = rpc([%{"books" => %{"fields" => ["title"]}}])
    end

    test "an atom-key envelope returns the same as the string-key one" do
      assert {:ok, string_keyed} =
               rpc([
                 %{"books" => %{"fields" => ["title"], "filter" => %{"title" => %{"eq" => "b"}}}}
               ])

      assert {:ok, ^string_keyed} =
               rpc([%{books: %{fields: [:title], filter: %{title: %{eq: "b"}}}}])
    end

    test "a to-one relationship takes a bare fields envelope" do
      author = create!(LoadRestrictions.Author, %{name: "Ann"})
      create!(LoadRestrictions.Article, %{title: "x", author_id: author.id})

      assert {:ok, [%{"author" => %{"name" => "Ann"}}]} =
               rpc(LoadRestrictions.Article, [%{"author" => %{"fields" => ["name"]}}])
    end

    test "envelopes nest: a filtered relationship holding a sorted one" do
      author = create!(LoadRestrictions.Author, %{name: "Ann"})
      kept = create!(LoadRestrictions.Article, %{title: "kept", author_id: author.id})
      create!(LoadRestrictions.Article, %{title: "dropped", author_id: author.id})

      for {body, weight} <- [{"light", 1}, {"heavy", 9}] do
        create!(LoadRestrictions.Comment, %{body: body, weight: weight, article_id: kept.id})
      end

      fields = [
        %{
          "articles" => %{
            "fields" => ["title", %{"comments" => %{"fields" => ["body"], "sort" => "-weight"}}],
            "filter" => %{"title" => %{"eq" => "kept"}}
          }
        }
      ]

      assert {:ok, [%{"articles" => [article]}]} = rpc(LoadRestrictions.Author, fields)

      assert article == %{
               "title" => "kept",
               "comments" => [%{"body" => "heavy"}, %{"body" => "light"}]
             }
    end

    test "a load restriction refuses the envelope as it refuses the plain load" do
      config = %{load_restrictions: {:deny, [:articles]}}

      assert {:error, %{"type" => "load_denied", "fields" => ["articles"]}} =
               rpc(
                 LoadRestrictions.Author,
                 [
                   %{
                     "articles" => %{
                       "fields" => ["title"],
                       "filter" => %{"title" => %{"eq" => "x"}}
                     }
                   }
                 ],
                 config
               )
    end

    test "a plain nested list and a calculation's args envelope still work" do
      author = create!(LoadRestrictions.Author, %{name: "Ann"})
      create!(LoadRestrictions.Article, %{title: "x", author_id: author.id})

      assert {:ok, [%{"books" => books}]} = rpc([%{"books" => ["title"]}])

      assert Enum.sort_by(books, & &1["title"]) == [
               %{"title" => "a"},
               %{"title" => "b"},
               %{"title" => "c"}
             ]

      assert {:ok, [%{"prefixedTitle" => "Dr-x"}]} =
               rpc(LoadRestrictions.Article, [
                 %{"prefixedTitle" => %{"args" => %{prefix: "Dr-"}}}
               ])
    end
  end

  describe "a relationship query envelope the relationship cannot take" do
    test "args beside a query option" do
      assert {:error, %{"type" => "invalid_query_opts", "fields" => ["books"]}} =
               rpc([%{"books" => %{"fields" => ["title"], "args" => %{}, "filter" => %{}}}])
    end

    test "query options on an attribute" do
      assert {:error, %{"type" => "invalid_query_opts", "fields" => ["name"]}} =
               rpc([%{"name" => %{"fields" => [], "sort" => "name"}}])
    end

    test "query options on a to-one relationship" do
      assert {:error, %{"type" => "invalid_query_opts", "fields" => ["author"]}} =
               rpc(LoadRestrictions.Article, [
                 %{"author" => %{"fields" => ["name"], "filter" => %{"name" => %{"eq" => "x"}}}}
               ])
    end

    test "page on a relationship whose read cannot paginate" do
      assert {:error,
              %{
                "type" => "pagination_not_supported",
                "fields" => ["foundBooks"],
                "details" => %{"reason" => "unsupported"}
              }} =
               rpc([%{"foundBooks" => %{"fields" => ["title"], "page" => %{"limit" => 1}}}])
    end

    # `notes` does not require pagination, so only the page-xor-limit check
    # can refuse this request.
    test "a destination the consumer does not expose" do
      hide_books = fn resource -> resource != RelPagination.Book end

      assert {:error, %{"type" => "unknown_field", "fields" => ["books"]}} =
               rpc(
                 [%{"books" => %{"fields" => ["title"], "sort" => "title"}}],
                 %{is_interop_resource?: hide_books}
               )
    end

    test "page with bare limit" do
      assert {:error, %{"type" => "invalid_query_opts", "message" => message}} =
               rpc([
                 %{"notes" => %{"fields" => ["body"], "page" => %{"limit" => 1}, "limit" => 1}}
               ])

      assert message =~ "combines page with bare limit/offset"
    end

    test "a page that is not a map" do
      assert {:error, %{"type" => "invalid_pagination", "fields" => ["books"]}} =
               rpc([%{"books" => %{"fields" => ["title"], "page" => 5}}])
    end

    test "query options on a field the resource does not have" do
      assert {:error, %{"type" => "unknown_field", "fields" => ["nope"]}} =
               rpc([%{"nope" => %{"fields" => ["title"], "sort" => "title"}}])
    end

    test "bare limit on a relationship whose read requires pagination names page" do
      assert {:error, %{"type" => "invalid_query_opts", "message" => message}} =
               rpc([%{"books" => %{"fields" => ["title"], "limit" => 1}}])

      assert message =~ "send page"
    end

    test "an unknown page key" do
      assert {:error, %{"type" => "invalid_pagination", "fields" => ["books"]}} =
               rpc([%{"books" => %{"fields" => ["title"], "page" => %{"cursor" => 1}}}])
    end

    test "empty fields" do
      assert {:error, %{"type" => "requires_field_selection"}} =
               rpc([%{"books" => %{"fields" => [], "sort" => "title"}}])
    end

    test "filter with filtering disabled in the config" do
      assert {:error, %{"type" => "filter_not_supported", "details" => %{"reason" => "disabled"}}} =
               rpc(
                 [
                   %{
                     "books" => %{"fields" => ["title"], "filter" => %{"title" => %{"eq" => "b"}}}
                   }
                 ],
                 %{enable_filter?: false}
               )
    end

    test "sort with sorting disabled in the config" do
      assert {:error, %{"type" => "sort_not_supported", "details" => %{"reason" => "disabled"}}} =
               rpc([%{"books" => %{"fields" => ["title"], "sort" => "title"}}], %{
                 enable_sort?: false
               })
    end

    # Owner's answer to question 1 on #24, given in chat: refuse, as upstream.
    test "filter or sort on a relationship marked filterable?: false, sortable?: false" do
      assert {:error,
              %{
                "type" => "filter_not_supported",
                "fields" => ["sealedBooks"],
                "details" => %{"reason" => "unsupported"}
              }} =
               rpc([
                 %{
                   "sealedBooks" => %{
                     "fields" => ["title"],
                     "filter" => %{"title" => %{"eq" => "b"}}
                   }
                 }
               ])

      assert {:error,
              %{
                "type" => "sort_not_supported",
                "fields" => ["sealedBooks"],
                "details" => %{"reason" => "unsupported"}
              }} = rpc([%{"sealedBooks" => %{"fields" => ["title"], "sort" => "title"}}])
    end

    test "a config that disables filtering wins over a relationship that forbids it" do
      assert {:error, %{"type" => "filter_not_supported", "details" => %{"reason" => "disabled"}}} =
               rpc(
                 [
                   %{
                     "sealedBooks" => %{
                       "fields" => ["title"],
                       "filter" => %{"title" => %{"eq" => "b"}}
                     }
                   }
                 ],
                 %{enable_filter?: false}
               )
    end

    test "a config that disables sorting wins over a relationship that forbids it" do
      assert {:error, %{"type" => "sort_not_supported", "details" => %{"reason" => "disabled"}}} =
               rpc([%{"sealedBooks" => %{"fields" => ["title"], "sort" => "title"}}], %{
                 enable_sort?: false
               })
    end
  end

  defp rpc(fields), do: rpc(RelPagination.Library, fields, %{})
  defp rpc(resource, fields) when is_atom(resource), do: rpc(resource, fields, %{})
  defp rpc(fields, extra) when is_list(fields), do: rpc(RelPagination.Library, fields, extra)

  defp rpc(resource, fields, extra) do
    config = ManifestFixture.decorated_config(extra)

    case FieldSelector.process(resource, :read, fields, config) do
      {:error, error} ->
        {:error, json(ErrorBuilder.build_error_response(error))}

      {:ok, {select, load, template}} ->
        request =
          Request.new(%{
            domain: Ash.Resource.Info.domain(resource),
            resource: resource,
            action: Ash.Resource.Info.action(resource, :read),
            rpc_action: %{},
            input: %{},
            context: %{},
            select: select,
            load: load,
            extraction_template: template,
            show_metadata: []
          })

        with {:ok, result} <- Pipeline.execute_ash_action(request, config),
             {:ok, processed} <- Pipeline.process_result(result, request, config) do
          %{"data" => data} =
            %{success: true, data: processed}
            |> Pipeline.format_output_with_request(request, config)
            |> json()

          {:ok, data}
        end
    end
  end

  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp create!(resource, attrs) do
    resource
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!()
  end
end
