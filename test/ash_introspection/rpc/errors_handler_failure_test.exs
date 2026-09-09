# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.ErrorsHandlerFailureTest do
  @moduledoc """
  A configured error handler is the application's only hook for redacting an
  error before it reaches the client. When that hook crashes, returning the
  error it was supposed to sanitize hands the client exactly the disclosure the
  handler existed to prevent — the one path in the pipeline that must fail
  closed instead failing open.

  Handlers are usually written as a function head matching the error shapes the
  developer anticipated, so an unanticipated shape raises `FunctionClauseError`
  rather than being passed through deliberately. These tests pin the closed
  behaviour for a handler that raises, throws and exits.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshIntrospection.Rpc.Errors

  @secret "search backend unreachable at es.internal:9200 (token=S3cr3t-Pr0d-Pw)"

  defmodule RaisingHandler do
    @moduledoc false
    def handle_rpc_error(%{type: "invalid_attribute"} = error, _context) do
      %{error | message: "Invalid value.", short_message: "Invalid value", vars: %{}}
    end

    # No clause for any other error type -> FunctionClauseError.
  end

  defmodule ThrowingHandler do
    @moduledoc false
    def handle_rpc_error(_error, _context), do: throw(:handler_bailed)
  end

  defmodule ExitingHandler do
    @moduledoc false
    def handle_rpc_error(_error, _context), do: exit(:handler_gave_up)
  end

  describe "a handler that succeeds" do
    test "redacts the error class it matches" do
      [response] = to_errors(RaisingHandler, invalid_attribute())

      assert response.message == "Invalid value."
      refute leaks_secret?(response)
    end
  end

  describe "a handler that crashes" do
    test "returns a generic error when the handler raises" do
      assert_fails_closed(RaisingHandler)
    end

    test "returns a generic error when the handler throws" do
      assert_fails_closed(ThrowingHandler)
    end

    test "returns a generic error when the handler exits" do
      assert_fails_closed(ExitingHandler)
    end
  end

  describe "the log left behind by a crashed handler" do
    test "carries the error id the client was given" do
      {[response], log} = with_log(fn -> to_errors(RaisingHandler, invalid_argument()) end)

      assert log =~ response.error_id
    end

    test "carries the handler, the failure and the original error" do
      {_response, log} = with_log(fn -> to_errors(RaisingHandler, invalid_argument()) end)

      assert log =~ inspect(RaisingHandler)
      assert log =~ "FunctionClauseError"
      assert log =~ @secret
    end

    test "names the kind and reason for a handler that throws" do
      {_response, log} = with_log(fn -> to_errors(ThrowingHandler, invalid_argument()) end)

      assert log =~ "throw: :handler_bailed"
    end

    test "names the kind and reason for a handler that exits" do
      {_response, log} = with_log(fn -> to_errors(ExitingHandler, invalid_argument()) end)

      assert log =~ "exit: :handler_gave_up"
    end
  end

  defp assert_fails_closed(handler) do
    {[response], _log} = with_log(fn -> to_errors(handler, invalid_argument()) end)

    assert response.code == "internal_error"
    assert response.short_message == "Internal error"
    assert response.vars == %{}
    assert response.fields == []
    assert is_binary(response.error_id)
    assert response.message == "Something went wrong. Unique error id: #{response.error_id}"
    refute leaks_secret?(response)
  end

  defp to_errors(handler, error) do
    Errors.to_errors(error, nil, handler, nil, %{}, %{})
  end

  # An error class the handler has no clause for, carrying a sentinel that must
  # never reach the client.
  defp invalid_argument do
    Ash.Error.Query.InvalidArgument.exception(field: :filter, message: @secret)
  end

  defp invalid_attribute do
    Ash.Error.Changes.InvalidAttribute.exception(field: :email, message: @secret)
  end

  defp leaks_secret?(value) when is_binary(value), do: String.contains?(value, @secret)
  defp leaks_secret?(value) when is_atom(value), do: leaks_secret?(Atom.to_string(value))
  defp leaks_secret?(%_{} = value), do: value |> Map.from_struct() |> leaks_secret?()

  defp leaks_secret?(value) when is_map(value) do
    Enum.any?(value, fn {key, val} -> leaks_secret?(key) or leaks_secret?(val) end)
  end

  defp leaks_secret?(value) when is_list(value), do: Enum.any?(value, &leaks_secret?/1)
  defp leaks_secret?(value) when is_tuple(value), do: value |> Tuple.to_list() |> leaks_secret?()
  defp leaks_secret?(_value), do: false
end
