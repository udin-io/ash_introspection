# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.ProtocolRaisingError do
  @moduledoc false
  defexception [:message, :path]
end

defmodule AshIntrospection.Test.ProtocolThrowingError do
  @moduledoc false
  defexception [:message, :path]
end

defmodule AshIntrospection.Test.ProtocolExitingError do
  @moduledoc false
  defexception [:message, :path]
end

defimpl AshIntrospection.Rpc.Error, for: AshIntrospection.Test.ProtocolRaisingError do
  def to_error(_error), do: raise(ArgumentError, "protocol implementation blew up")
end

defimpl AshIntrospection.Rpc.Error, for: AshIntrospection.Test.ProtocolThrowingError do
  def to_error(_error), do: throw(:protocol_bailed)
end

defimpl AshIntrospection.Rpc.Error, for: AshIntrospection.Test.ProtocolExitingError do
  def to_error(_error), do: exit(:protocol_gave_up)
end

defmodule AshIntrospection.Rpc.ErrorsProtocolFailureTest do
  @moduledoc """
  `AshIntrospection.Rpc.Error` implementations are consumer code, so they fail
  every way code fails. Error transformation is the last thing standing between
  a failed request and the caller: a failure that escapes `to_errors/6` takes
  the request with it and the client learns nothing at all.

  The raising case was already caught. A `throw` or an `exit` is not an
  exception, so `rescue` never saw it and it propagated out of error handling —
  #40. These tests pin all three kinds to the same opaque fallback, and pin the
  log that is the only way to join that fallback to the real failure.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshIntrospection.Rpc.Errors
  alias AshIntrospection.Test.ProtocolExitingError
  alias AshIntrospection.Test.ProtocolRaisingError
  alias AshIntrospection.Test.ProtocolThrowingError

  @secret "connection refused to vault.internal:8200 (token=S3cr3t-Pr0d-Pw)"

  describe "a protocol implementation that fails" do
    test "returns the opaque fallback when it raises" do
      assert_opaque_fallback(ProtocolRaisingError)
    end

    test "returns the opaque fallback when it throws" do
      assert_opaque_fallback(ProtocolThrowingError)
    end

    test "returns the opaque fallback when it exits" do
      assert_opaque_fallback(ProtocolExitingError)
    end
  end

  describe "the path of an error whose implementation fails" do
    test "survives a throw" do
      {[response], _log} =
        with_log(fn -> to_errors(ProtocolThrowingError, path: [:audit_log]) end)

      assert response.path == ["auditLog"]
    end
  end

  describe "the log left behind by a failed implementation" do
    test "names the failure and the original error when it raises" do
      {_response, log} = with_log(fn -> to_errors(ProtocolRaisingError) end)

      assert log =~ "ArgumentError"
      assert log =~ "protocol implementation blew up"
      assert log =~ inspect(ProtocolRaisingError)
      assert log =~ @secret
    end

    test "names the kind and reason when it throws" do
      {_response, log} = with_log(fn -> to_errors(ProtocolThrowingError) end)

      assert log =~ "throw: :protocol_bailed"
      assert log =~ inspect(ProtocolThrowingError)
      assert log =~ @secret
    end

    test "names the kind and reason when it exits" do
      {_response, log} = with_log(fn -> to_errors(ProtocolExitingError) end)

      assert log =~ "exit: :protocol_gave_up"
      assert log =~ inspect(ProtocolExitingError)
      assert log =~ @secret
    end
  end

  defp assert_opaque_fallback(error_module) do
    {[response], _log} = with_log(fn -> to_errors(error_module) end)

    assert response.message == "something went wrong"
    assert response.short_message == "Error"
    assert response.type == "error"
    assert response.vars == %{}
    assert response.fields == []
    refute leaks_secret?(response)
  end

  # `Ash.Error.to_error_class/1` turns a bare exception into an
  # `Ash.Error.Unknown.UnknownError`, whose own implementation never fails.
  # Wrapping it in an Ash class first keeps the struct intact, so the protocol
  # lookup reaches the implementation under test.
  defp to_errors(error_module, opts \\ []) do
    error = error_module.exception(Keyword.merge([message: @secret, path: []], opts))

    Errors.to_errors(
      Ash.Error.Invalid.exception(errors: [error]),
      nil,
      nil,
      nil,
      %{},
      %{}
    )
  end

  defp leaks_secret?(value) when is_binary(value), do: String.contains?(value, @secret)
  defp leaks_secret?(value) when is_atom(value), do: leaks_secret?(Atom.to_string(value))

  defp leaks_secret?(value) when is_map(value) do
    Enum.any?(value, fn {key, val} -> leaks_secret?(key) or leaks_secret?(val) end)
  end

  defp leaks_secret?(value) when is_list(value), do: Enum.any?(value, &leaks_secret?/1)
  defp leaks_secret?(_value), do: false
end
