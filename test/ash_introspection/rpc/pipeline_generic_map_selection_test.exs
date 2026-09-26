# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineGenericMapSelectionTest do
  @moduledoc """
  #89: a generic action returning a map with declared `fields` answers a
  nested selection with exactly the fields selected.

  Ash hands a `run` result back uncast, so the keys reach stage 3 as the
  action wrote them, atoms or strings. Each test drives the four entry points
  a consumer calls and asserts the response the client receives.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.FieldProcessing.FieldSelector
  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.ManifestFixture
  alias AshIntrospection.Test.MapTile
  alias AshIntrospection.Test.Post

  defp response(resource \\ MapTile, action, requested_fields) do
    config = ManifestFixture.decorated_config()

    assert {:ok, {select, load, template}} =
             FieldSelector.process(resource, action, requested_fields, config)

    request =
      Request.new(%{
        domain: Ash.Resource.Info.domain(resource),
        resource: resource,
        action: Ash.Resource.Info.action(resource, action),
        rpc_action: %{},
        input: %{},
        context: %{},
        select: select,
        load: load,
        extraction_template: template,
        show_metadata: []
      })

    {:ok, ash_result} = Pipeline.execute_ash_action(request, config)
    {:ok, processed} = Pipeline.process_result(ash_result, request, config)
    Pipeline.format_output_with_request(%{success: true, data: processed}, request, config)
  end

  describe "a nested selection on a tuple inside a generic action's map" do
    test "returns the selected element of a map built with atom keys" do
      assert %{"data" => data} = response(:get_tile_map, ["name", %{"span" => ["y"]}])
      assert data == %{"name" => "north-west", "span" => %{"y" => 2.5}}
    end

    test "returns the selected element of a map built with string keys" do
      assert %{"data" => data} = response(:get_tile_map_strings, ["name", %{"span" => ["y"]}])
      assert data == %{"name" => "north-west", "span" => %{"y" => 2.5}}
    end

    test "returns the selected element in every row of an array of maps" do
      assert %{"data" => data} = response(:list_tile_maps, ["name", %{"span" => ["y"]}])

      assert data == [
               %{"name" => "north-west", "span" => %{"y" => 2.5}},
               %{"name" => "south-east", "span" => %{"y" => 4.5}}
             ]
    end

    test "returns the selected element of a tuple in a map in a list in a map" do
      fields = ["region", %{"tiles" => ["name", %{"span" => ["x"]}]}]
      assert %{"data" => data} = response(:get_region, fields)

      assert data == %{
               "region" => "north",
               "tiles" => [
                 %{"name" => "north-west", "span" => %{"x" => 1.5}},
                 %{"name" => "north-east", "span" => %{"x" => 3.5}}
               ]
             }
    end
  end

  describe "a key the action returns but never declared" do
    test "does not reach the client" do
      assert %{"data" => data} = response(:get_tile_meta, ["name", "meta"])
      assert data == %{"name" => "north-west", "meta" => %{"zoom" => 12}}
    end
  end

  describe "selections that already worked" do
    test "a flat selection returns both elements of the tuple" do
      assert %{"data" => data} = response(:get_tile_map, ["name", "span"])
      assert data == %{"name" => "north-west", "span" => %{"x" => 1.5, "y" => 2.5}}
    end

    test "a flat selection of a string-keyed map returns every value" do
      assert %{"data" => data} = response(:get_tile_map_strings, ["name", "span", "meta"])

      assert data == %{
               "name" => "north-west",
               "span" => %{"x" => 1.5, "y" => 2.5},
               "meta" => %{"zoom" => 12}
             }
    end

    test "a nested map selection on a string-keyed map returns the value" do
      assert %{"data" => data} = response(:get_tile_map_strings, ["name", %{"meta" => ["zoom"]}])
      assert data == %{"name" => "north-west", "meta" => %{"zoom" => 12}}
    end

    test "a string-keyed field holding false comes back false" do
      assert %{"data" => data} = response(:get_tile_map_strings, ["visible"])
      assert data == %{"visible" => false}
    end

    test "an atom-keyed field holding false comes back false" do
      assert %{"data" => data} = response(:get_tile_map, ["visible"])
      assert data == %{"visible" => false}
    end

    test "a NewType map keeps its pinned client names" do
      assert %{"data" => data} =
               response(Post, :get_task_stats, ["isActive", "taskCount", "meta1"])

      assert data == %{"isActive" => true, "taskCount" => 0, "meta1" => "none"}
    end

    test "a read of a map attribute returns the selected element" do
      Ash.Seed.seed!(MapTile, %{area: %{name: "north-west", span: {1.5, 2.5}}})

      assert %{"data" => data} = response(:read, [%{"area" => ["name", %{"span" => ["y"]}]}])
      assert data == [%{"area" => %{"name" => "north-west", "span" => %{"y" => 2.5}}}]
    end
  end
end
