# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.ErrorsEmptyClassTest do
  @moduledoc """
  An error class with no inner error still reaches the client as one error,
  never as `success: false` with an empty `errors` list.
  `Ash.Authorizer.exception/3` builds such an `Ash.Error.Forbidden` for any
  authorizer without its own `exception/2`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshIntrospection.Rpc.ErrorBuilder

  test "an empty forbidden class returns one forbidden error" do
    assert [error] = ErrorBuilder.build_error_response(Ash.Error.Forbidden.exception([]))
    assert error.type == "forbidden"
    assert error.message == "forbidden"
  end

  test "a forbidden class with an inner error returns that error once" do
    class = Ash.Error.Forbidden.exception(errors: [Ash.Error.Forbidden.Policy.exception([])])

    assert [%{type: "forbidden"}] = ErrorBuilder.build_error_response(class)
  end

  for class <- [Ash.Error.Invalid, Ash.Error.Unknown, Ash.Error.Framework] do
    test "an empty #{inspect(class)} returns one internal_error" do
      capture_log(fn ->
        assert [%{type: "internal_error"}] =
                 ErrorBuilder.build_error_response(unquote(class).exception([]))
      end)
    end
  end
end
