# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineNoReturnActionTest do
  @moduledoc """
  #85: a generic action with no return type hands back `:ok`, so there is
  nothing to select from. A non-empty `fields` gets an
  `invalid_field_selection` error, never a crash and never a made-up `nil`.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.ErrorBuilder
  alias AshIntrospection.Rpc.FieldProcessing.FieldSelector
  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.ManifestFixture
  alias AshIntrospection.Test.MapTile

  defp request(select, load, template) do
    Request.new(%{
      domain: Ash.Resource.Info.domain(MapTile),
      resource: MapTile,
      action: Ash.Resource.Info.action(MapTile, :touch_tile),
      rpc_action: %{},
      input: %{},
      context: %{},
      select: select,
      load: load,
      extraction_template: template,
      show_metadata: []
    })
  end

  defp response(requested_fields) do
    config = ManifestFixture.decorated_config()

    case FieldSelector.process(MapTile, :touch_tile, requested_fields, config) do
      {:ok, {select, load, template}} ->
        request = request(select, load, template)
        {:ok, ash_result} = Pipeline.execute_ash_action(request, config)
        {:ok, processed} = Pipeline.process_result(ash_result, request, config)
        Pipeline.format_output_with_request(%{success: true, data: processed}, request, config)

      {:error, error} ->
        Pipeline.format_output_with_request(
          %{success: false, errors: [ErrorBuilder.build_error_response(error)]},
          request([], [], []),
          config
        )
    end
  end

  for fields <- [["foo"], [:foo], [%{"foo" => ["bar"]}]] do
    test "fields #{inspect(fields)} gets an error saying the action returns no value" do
      assert %{"success" => false, "errors" => [error]} = response(unquote(Macro.escape(fields)))
      assert error["type"] == "invalid_field_selection"
      assert error["message"] == "Cannot select fields: the action returns no value"
    end
  end

  test "an empty field list succeeds with empty data" do
    assert response([]) == %{"success" => true, "data" => %{}}
  end
end
