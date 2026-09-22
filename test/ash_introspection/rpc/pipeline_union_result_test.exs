# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineUnionResultTest do
  @moduledoc """
  Pins that a union value survives stages 3 and 4 with the members and fields
  the caller selected. #84.

  Two causes, measured on `main` at `60666a8`:

  1. `FieldSelector.process_nested_union_member/8` keyed a nested member entry
     by the wire name (`{"summary", [:label]}`). `ResultProcessor` compares
     member names as atoms, so the value came back `nil` and a list dropped
     the item. It hit reads and generic actions alike. #35 was the same
     mistake in tuples.
  2. `ResultProcessor.determine_data_type/3` typed a top-level `%Ash.Union{}`
     from the owning resource's first union attribute, never from the generic
     action's own return constraints. `Test.Shelf.badge` is that first
     attribute, and it disagrees with the actions on purpose. The selection
     was ignored and undeclared keys leaked.

  Each request goes through `FieldSelector.process/4`, `Pipeline` stages 2
  and 3, and `format_output_with_request/3`, as a consumer calls them. The
  `{:template, _}` requests build the template by hand, with atom member
  names, so the second cause shows on its own.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.FieldProcessing.FieldSelector
  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.ManifestFixture
  alias AshIntrospection.Test.Shelf
  alias AshIntrospection.Test.UnionResultDomain

  @every_member [%{"summary" => ["label"]}, %{"counts" => ["bookCount"]}, "note"]

  defp request(action_name, template_or_fields, input \\ %{})

  defp request(action_name, {:template, template}, input) do
    build_request(action_name, {[], [], template}, input)
  end

  defp request(action_name, fields, input) do
    {:ok, selection} =
      FieldSelector.process(Shelf, action_name, fields, ManifestFixture.decorated_config())

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
    {:ok, ash_result} = Pipeline.execute_ash_action(request, ManifestFixture.decorated_config())

    {:ok, processed} =
      Pipeline.process_result(ash_result, request, ManifestFixture.decorated_config())

    %{"data" => data} =
      Pipeline.format_output_with_request(
        %{success: true, data: processed},
        request,
        ManifestFixture.decorated_config()
      )

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
        FieldSelector.process(
          Shelf,
          :read,
          ["title", %{"content" => @every_member}],
          ManifestFixture.decorated_config()
        )

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

  describe "a generic action returning one union value" do
    test "returns an embedded-resource member with only the selected fields" do
      assert data(request(:pick_content, @every_member, %{member: :summary})) ==
               %{"summary" => %{"label" => "U"}}
    end

    test "returns a typed-map member with only the selected fields" do
      assert data(request(:pick_content, @every_member, %{member: :counts})) ==
               %{"counts" => %{"bookCount" => 3}}
    end

    test "returns a scalar member" do
      assert data(request(:pick_content, @every_member, %{member: :note})) ==
               %{"note" => "plain"}
    end

    test "types members from the action's return constraints, not the owner's first union attribute" do
      template = {:template, [{:summary, [:label]}, {:counts, [:book_count]}, :note]}

      assert data(request(:pick_content, template, %{member: :summary})) ==
               %{"summary" => %{"label" => "U"}}

      assert data(request(:pick_content, template, %{member: :counts})) ==
               %{"counts" => %{"bookCount" => 3}}
    end
  end

  describe "a generic action returning a NewType over a union" do
    test "types members from the NewType's constraints" do
      assert data(request(:pick_wrapped_content, @every_member, %{member: :counts})) ==
               %{"counts" => %{"bookCount" => 3}}
    end
  end

  describe "a generic action returning a list of union values" do
    test "keeps every item, in order, with only the selected fields" do
      assert data(request(:all_content, @every_member)) == [
               %{"summary" => %{"label" => "U"}},
               %{"counts" => %{"bookCount" => 3}},
               %{"note" => "plain"}
             ]
    end
  end

  describe "a union return with an empty template" do
    # ash_kotlin_multiplatform #96 sends no `fields` for a union return and
    # expects the member that came back, with that member's declared fields.
    test "returns the active member's declared fields and nothing undeclared" do
      assert data(request(:pick_content, {:template, []}, %{member: :counts})) ==
               %{"counts" => %{"bookCount" => 3, "topTitle" => "C"}}
    end
  end
end
