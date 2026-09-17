# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineUnionResultTest do
  @moduledoc """
  Pins that a union value survives stages 3 and 4 with the members and fields
  the caller selected. #84.

  `FieldSelector.process_nested_union_member/8` keyed a nested member entry by
  the wire name (`{"summary", [:label]}`). `ResultProcessor` compares member
  names as atoms, so the value came back `nil`. Measured on `main` at
  `60666a8`: a read selecting `content` with nested member fields returned
  `nil` for the `summary` and `counts` records. #35 was the same mistake in
  tuples.

  Each request goes through `FieldSelector.process/4`, `Pipeline` stages 2
  and 3, and `format_output_with_request/3`, as a consumer calls them.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.FieldProcessing.FieldSelector
  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.Shelf
  alias AshIntrospection.Test.UnionResultDomain

  @every_member [%{"summary" => ["label"]}, %{"counts" => ["bookCount"]}, "note"]

  defp request(action_name, fields, input \\ %{}) do
    {:ok, selection} = FieldSelector.process(Shelf, action_name, fields, %{})
    build_request(action_name, selection, input)
  end

  defp build_request(action_name, {select, load, template}, input) do
    Request.new(%{
      domain: UnionResultDomain,
      resource: Shelf,
      action: Ash.Resource.Info.action(Shelf, action_name),
      rpc_action: %{},
      input: input,
      context: %{},
      select: select,
      load: load,
      extraction_template: template,
      show_metadata: []
    })
  end

  defp data(request) do
    {:ok, ash_result} = Pipeline.execute_ash_action(request)
    {:ok, processed} = Pipeline.process_result(ash_result, request)

    %{"data" => data} =
      Pipeline.format_output_with_request(%{success: true, data: processed}, request)

    data
  end

  defp member_name({name, _nested}), do: name
  defp member_name(name), do: name

  describe "a read selecting union members with nested fields" do
    setup do
      for {title, content} <- [
            {"a-summary", %Ash.Union{type: :summary, value: %{label: "L", pages: 9}}},
            {"b-counts", %Ash.Union{type: :counts, value: %{book_count: 1, top_title: "T"}}},
            {"c-note", %Ash.Union{type: :note, value: "n"}}
          ] do
        Shelf
        |> Ash.Changeset.for_create(:create, %{title: title, content: content})
        |> Ash.create!()
      end

      :ok
    end

    test "keys every member entry in the template by its atom" do
      {:ok, {_select, _load, template}} =
        FieldSelector.process(Shelf, :read, ["title", %{"content" => @every_member}], %{})

      {:content, members} = List.keyfind(template, :content, 0)

      assert members |> Enum.map(&member_name/1) |> Enum.sort() == [:counts, :note, :summary]
    end

    test "returns each record's member with only the selected fields" do
      records =
        :read
        |> request(["title", %{"content" => @every_member}])
        |> data()
        |> Enum.sort_by(& &1["title"])

      assert records == [
               %{"title" => "a-summary", "content" => %{"summary" => %{"label" => "L"}}},
               %{"title" => "b-counts", "content" => %{"counts" => %{"bookCount" => 1}}},
               %{"title" => "c-note", "content" => %{"note" => "n"}}
             ]
    end
  end
end
