# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.FieldProcessing.FieldSelectorTupleNestedTest do
  @moduledoc """
  Issue #35: the `{:nested, ...}` branch of
  `FieldSelector.select_tuple_fields/4` keyed its extraction template from the
  raw wire name while every sibling branch keyed it from the resolved atom.

  The issue asked for a test before a fix, because the inconsistency might have
  produced the same output either way. It does not. Measured on `main` at
  `b99e5a3` against `Test.MapTile.get_tile`, a tuple of
  `{label :: string, corner :: map(x, y)}` holding `{"north-west", %{x: 1.5,
  y: 2.5}}`:

      ["label", "corner"]          -> %{"corner" => %{"x" => 1.5, "y" => 2.5},
                                        "label" => "north-west"}
      [%{"corner" => ["x", "y"]}]  -> %{}

  The nested request lost the field entirely. `ResultProcessor` matches a
  nested template entry as `{field_atom, nested_template} when is_atom(...)`,
  so a string key fell through its catch-all and nothing was written. The same
  field asked for through the `{:multi_nested, ...}` branch — which already
  resolved the atom — came back as `%{"corner" => nil}`, so two spellings of
  one request gave three different answers.

  Fixing the key makes the two nested spellings agree. It does **not** make
  either return the value: a nested entry carries no tuple index, and
  `FieldExtractor.convert_tuple_to_map/2` can only place a field it has an
  index for. That gap is #66; the last test here pins the `nil` so the fix for
  it has to come back and change this file.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.FieldProcessing.FieldSelector
  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.ManifestFixture
  alias AshIntrospection.Test.MapTile
  alias AshIntrospection.Test.TupleSelectionDomain

  defp select(requested_fields, action \\ :get_tile) do
    assert {:ok, {select, load, template}} =
             FieldSelector.process(
               MapTile,
               action,
               requested_fields,
               ManifestFixture.decorated_config()
             )

    {select, load, template}
  end

  defp template(requested_fields) do
    {_select, _load, template} = select(requested_fields)
    template
  end

  defp response(requested_fields, action \\ :get_tile) do
    {select, load, template} = select(requested_fields, action)

    request =
      %{
        domain: TupleSelectionDomain,
        resource: MapTile,
        action: Ash.Resource.Info.action(MapTile, action),
        rpc_action: %{},
        input: %{},
        context: %{},
        select: select,
        load: load,
        extraction_template: template,
        show_metadata: []
      }
      |> Request.new()

    {:ok, ash_result} = Pipeline.execute_ash_action(request, ManifestFixture.decorated_config())

    {:ok, processed} =
      Pipeline.process_result(ash_result, request, ManifestFixture.decorated_config())

    Pipeline.format_output_with_request(
      %{success: true, data: processed},
      request,
      ManifestFixture.decorated_config()
    )
  end

  describe "the premise" do
    test "a flat selection carries the resolved atom and the tuple index" do
      assert template(["label", "corner"]) == [
               %{field_name: :label, index: 0},
               %{field_name: :corner, index: 1}
             ]
    end

    test "a flat selection returns both fields of the tuple" do
      assert %{"data" => data, "success" => true} = response(["label", "corner"])
      assert data == %{"label" => "north-west", "corner" => %{"x" => 1.5, "y" => 2.5}}
    end
  end

  describe "a nested selection on a tuple field" do
    test "keys its template from the resolved atom and carries the index" do
      assert [%{field_name: :corner, index: 1, nested: [:x, :y]}] =
               template([%{"corner" => ["x", "y"]}])
    end

    test "keys it the same way the multi-entry spelling does" do
      single = template([%{"corner" => ["x"]}])
      multi = template([%{"corner" => ["x"], "label" => nil}])

      assert [%{field_name: :corner, index: 1, nested: [:x]}] = single
      assert %{field_name: :corner, index: 1, nested: [:x]} in multi
    end

    test "still rejects a nested field the tuple field does not have" do
      assert {:error, {:unknown_field, _, _, [:corner]}} =
               FieldSelector.process(
                 MapTile,
                 :get_tile,
                 [%{"corner" => ["z"]}],
                 ManifestFixture.decorated_config()
               )
    end
  end

  describe "the gap #35 left open, closed by #66" do
    # Before #35 the key was a string and the field vanished from the
    # response; after #35 it was present and `nil`, because a nested entry
    # carried no tuple index and `FieldExtractor.convert_tuple_to_map/2` can
    # only place a field it has an index for. #66 carries the index.
    test "the value survives: the field comes back with the selected key" do
      assert %{"data" => data} = response(["label", %{"corner" => ["x"]}])
      assert data == %{"label" => "north-west", "corner" => %{"x" => 1.5}}
    end
  end

  describe "a nested selection inside a tuple (#66)" do
    test "the multi-entry spelling returns the same value" do
      assert %{"data" => data} = response([%{"corner" => ["y"], "label" => nil}])
      assert data == %{"label" => "north-west", "corner" => %{"y" => 2.5}}
    end

    test "a tuple inside a tuple carries its index at both depths" do
      fields = ["label", %{"span" => [%{"from" => ["x"]}, %{"to" => ["y"]}]}]
      assert %{"data" => data} = response(fields, :get_tile_deep)

      assert data == %{
               "label" => "north-west",
               "span" => %{"from" => %{"x" => 1.5}, "to" => %{"y" => 4.5}}
             }
    end

    test "a map inside a map inside a tuple returns the innermost value" do
      fields = [%{"meta" => [%{"origin" => ["lat"]}, "zoom"]}]
      assert %{"data" => data} = response(fields, :get_tile_deep)
      assert data == %{"meta" => %{"origin" => %{"lat" => 30.0}, "zoom" => 12}}
    end

    # The second positional gap: a tuple-typed field selected flat reached
    # `ResultProcessor` with an empty template, so nothing carried its
    # positions and every inner field came back `nil`. The inner tuple now
    # gets the full positional template built from its `fields` constraint.
    test "a tuple-typed field selected flat returns every inner value" do
      assert %{"data" => data} = response(["label", "span"], :get_tile_deep)

      assert data == %{
               "label" => "north-west",
               "span" => %{
                 "from" => %{"x" => 1.5, "y" => 2.5},
                 "to" => %{"x" => 3.5, "y" => 4.5}
               }
             }
    end

    test "the flat selection keeps working beside a nested one" do
      assert %{"data" => data} = response(["label", "meta"], :get_tile_deep)

      assert data == %{
               "label" => "north-west",
               "meta" => %{"origin" => %{"lat" => 30.0, "lng" => 31.2}, "zoom" => 12}
             }
    end

    test "a tuple-typed field selected flat one level down returns its elements" do
      assert %{"data" => data} = response([%{"span" => ["from"]}], :get_tile_deep)
      assert data == %{"span" => %{"from" => %{"x" => 1.5, "y" => 2.5}}}
    end
  end

  # The same tuple reached through the other containers. A list is asserted
  # on every element: a first record that is right and a second that is not
  # is invisible to List.first/1 (see #57 in CLAUDE.md).
  describe "the tuple index through neighbouring containers (#66)" do
    test "an array of tuples places the nested field in every element" do
      assert %{"data" => data} = response([%{"corner" => ["x"]}, "label"], :list_tiles)

      assert data == [
               %{"label" => "north-west", "corner" => %{"x" => 1.5}},
               %{"label" => "south-east", "corner" => %{"x" => 3.5}}
             ]
    end

    # The gap this fix does not close, filed out of #66. A map at the top of
    # a generic action's result is typed `{nil, []}` by
    # `ResultProcessor.determine_data_type/3`, because Ash hands the `run`
    # result back uncast and the typed map path reads atom keys only (#62).
    # So a tuple inside it has no field types, its nested template is
    # ignored, and stage 4 formats the whole tuple: the client gets every
    # element instead of the one it asked for. Change this assertion when
    # that ticket lands; do not delete it.
    test "a tuple inside a map ignores the nested selection and returns every element" do
      assert %{"data" => data} = response(["name", %{"span" => ["y"]}], :get_tile_map)
      assert data == %{"name" => "north-west", "span" => %{"x" => 1.5, "y" => 2.5}}
    end

    test "a tuple inside a map selected flat returns every element" do
      assert %{"data" => data} = response(["name", "span"], :get_tile_map)
      assert data == %{"name" => "north-west", "span" => %{"x" => 1.5, "y" => 2.5}}
    end

    test "a tuple as a union member returns the nested value" do
      assert %{"data" => data} = response([%{"point" => ["x"]}], :pick_tile)
      assert data == %{"point" => %{"x" => 1.5}}
    end
  end
end
