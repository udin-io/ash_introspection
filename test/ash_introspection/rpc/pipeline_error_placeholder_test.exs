# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineErrorPlaceholderTest do
  @moduledoc """
  End-to-end guard on the error payload a client receives from stage 4.

  `AshIntrospection.Rpc.ErrorBuilder` writes messages as templates —
  `"RPC action %{action_name} not found"` with `vars: %{action_name: ...}` —
  and the client interpolates. Stage 4 camelized every nested key, `vars`
  included, without touching the message, so `%{action_name}` was left naming a
  key that had become `actionName` and interpolation silently produced nothing.

  These tests drive real `ErrorBuilder` payloads through
  `Pipeline.format_output_with_request/3` and assert that every placeholder in
  the response resolves against the response's own `vars`.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.ErrorBuilder
  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request

  @placeholder ~r/%\{([^}]+)\}/

  describe "a multi-word placeholder" do
    test "resolves against vars after formatting" do
      [error] = format([ErrorBuilder.build_error_response({:action_not_found, "get_todo"})])

      assert error["message"] == "RPC action %{actionName} not found"
      assert error["vars"]["actionName"] == "get_todo"
      assert interpolate(error["message"], error["vars"]) == "RPC action get_todo not found"
    end

    test "resolves for every error ErrorBuilder can raise with one" do
      errors =
        format([
          ErrorBuilder.build_error_response({:action_not_found, "get_todo"}),
          ErrorBuilder.build_error_response(
            {:unexpected_get_by_fields, [:colour], [:color, :size]}
          ),
          ErrorBuilder.build_error_response({:requires_field_selection, :primitive_type, nil}),
          ErrorBuilder.build_error_response(
            {:invalid_field_selection, :primitive_type, :string, [:name], [:todo]}
          ),
          ErrorBuilder.build_error_response(
            {:invalid_identity, %{provided_keys: [:id], expected_keys: [:email, :tenant_id]}}
          ),
          ErrorBuilder.build_error_response(
            {:invalid_union_input, :multiple_member_keys, [:text, :file], [:text]}
          )
        ])

      for error <- errors, {key, value} <- error, is_binary(value) do
        for name <- placeholders(value) do
          assert Map.has_key?(error["vars"], name) or
                   Map.has_key?(error["details"] || %{}, name),
                 "#{key} carries %{#{name}}, which names neither a vars nor a details key"
        end
      end
    end
  end

  describe "a single-word placeholder" do
    test "is left alone, and still resolves" do
      error = %{
        type: "required",
        message: "Field %{field} is required",
        short_message: "Required field",
        vars: %{field: "email"},
        fields: ["email"],
        path: []
      }

      [formatted] = format([error])

      assert formatted["message"] == "Field %{field} is required"
      assert interpolate(formatted["message"], formatted["vars"]) == "Field email is required"
    end
  end

  describe "an error raised before a request exists" do
    test "gets the same envelope and the same rewritten placeholders" do
      errors = [ErrorBuilder.build_error_response({:action_not_found, "get_todo"})]

      assert Pipeline.format_output(%{success: false, errors: errors}) ==
               Pipeline.format_output_with_request(
                 %{success: false, errors: errors},
                 %Request{},
                 %{}
               )
    end
  end

  describe "the success envelope" do
    test "is unaffected" do
      response =
        Pipeline.format_output_with_request(%{success: true}, %Request{}, %{})

      assert response == %{"success" => true}
    end
  end

  defp format(errors) do
    response =
      Pipeline.format_output_with_request(
        %{success: false, errors: List.flatten(errors)},
        %Request{},
        %{}
      )

    assert response["success"] == false
    response["errors"]
  end

  defp placeholders(string) do
    @placeholder |> Regex.scan(string) |> Enum.map(fn [_full, name] -> name end)
  end

  defp interpolate(message, vars) do
    Regex.replace(@placeholder, message, fn full, name ->
      Map.get(vars, name, full)
    end)
  end
end
