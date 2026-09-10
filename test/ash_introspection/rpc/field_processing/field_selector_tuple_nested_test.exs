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
  alias AshIntrospection.Test.MapTile
  alias AshIntrospection.Test.TupleSelectionDomain

  defp select(requested_fields) do
    assert {:ok, {select, load, template}} =
             FieldSelector.process(MapTile, :get_tile, requested_fields)

    {select, load, template}
  end

  defp template(requested_fields) do
    {_select, _load, template} = select(requested_fields)
    template
  end

  defp response(requested_fields) do
    {select, load, template} = select(requested_fields)

    request =
      %{
        domain: TupleSelectionDomain,
        resource: MapTile,
        action: Ash.Resource.Info.action(MapTile, :get_tile),
        rpc_action: %{},
        input: %{},
        context: %{},
        select: select,
        load: load,
        extraction_template: template,
        show_metadata: []
      }
      |> Request.new()

    {:ok, ash_result} = Pipeline.execute_ash_action(request)
    {:ok, processed} = Pipeline.process_result(ash_result, request)

    Pipeline.format_output_with_request(%{success: true, data: processed}, request)
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
    test "keys its template from the resolved atom, not the wire name" do
      assert [{:corner, [:x, :y]}] = template([%{"corner" => ["x", "y"]}])
    end

    test "keys it the same way the multi-entry spelling does" do
      single = template([%{"corner" => ["x"]}])
      multi = template([%{"corner" => ["x"], "label" => nil}])

      assert [{:corner, [:x]}] = single
      assert {:corner, [:x]} in multi
    end

    test "still rejects a nested field the tuple field does not have" do
      assert {:error, {:unknown_field, _, _, [:corner]}} =
               FieldSelector.process(MapTile, :get_tile, [%{"corner" => ["z"]}])
    end
  end

  describe "the gap this fix does not close (#66)" do
    # A nested template entry has no tuple index, so
    # `FieldExtractor.convert_tuple_to_map/2` cannot place the field and the
    # value is lost. Before #35 the key was a string and the field vanished
    # from the response; now it is present and `nil`. Change this assertion
    # when #66 lands — do not delete it.
    test "the value does not survive: the field comes back nil" do
      assert %{"data" => data} = response(["label", %{"corner" => ["x"]}])
      assert data == %{"label" => "north-west", "corner" => nil}
    end
  end
end
