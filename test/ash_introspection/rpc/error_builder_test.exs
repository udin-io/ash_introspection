# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.ErrorBuilderTest do
  @moduledoc """
  The pipeline rejects non-scalar identity and `get_by` values with
  `{:invalid_identity, _}` and `{:invalid_get_by, _}`. Both must reach the
  client as their own error type — without a clause they fall through to the
  generic `field_validation_error` fallback, which drops the message.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.ErrorBuilder

  describe "invalid_get_by" do
    test "keeps its own type, message and path" do
      error =
        ErrorBuilder.build_error_response(
          {:invalid_get_by,
           %{
             message:
               "getBy values must be scalar equality operands. Non-scalar value provided for: email"
           }}
        )

      assert error.type == "invalid_get_by"
      assert error.message =~ "scalar equality operands"
      assert error.message =~ "email"
      assert error.path == [:get_by]
    end
  end

  describe "invalid_identity" do
    test "keeps its own type and message when built from a bare message" do
      error =
        ErrorBuilder.build_error_response(
          {:invalid_identity,
           %{
             message:
               "Identity values must be scalar equality operands. Non-scalar value provided for: email"
           }}
        )

      assert error.type == "invalid_identity"
      assert error.message =~ "scalar equality operands"
      assert error.path == [:identity]
    end
  end
end
