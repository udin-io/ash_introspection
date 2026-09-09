# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.UnhandledError do
  @moduledoc false
  defexception [:message, :path]
end

defmodule AshIntrospection.Test.ExplodingError do
  @moduledoc false
  defexception [:message, :path]
end

defimpl AshIntrospection.Rpc.Error, for: AshIntrospection.Test.ExplodingError do
  def to_error(_error), do: raise("protocol implementation blew up")
end

defmodule AshIntrospection.Rpc.ErrorTypeKeyTest do
  @moduledoc """
  Every error the RPC pipeline hands a client must name its class under `type`.

  `AshIntrospection.Rpc.Error` implementations already emit `type`, but the
  fallback paths in `AshIntrospection.Rpc.Errors` emitted `code`. A client
  reading `error.type` therefore got `nil` for exactly the errors it could not
  anticipate — an exception with no protocol implementation, a protocol
  implementation that raised, or a domain with `show_raised_errors?` set. These
  tests walk each of those paths and assert on the key the client reads.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshIntrospection.Rpc.Error, as: ErrorProtocol
  alias AshIntrospection.Rpc.Errors
  alias AshIntrospection.Test.ExplodingError
  alias AshIntrospection.Test.RaisingErrorsDomain
  alias AshIntrospection.Test.UnhandledError

  describe "an exception with no protocol implementation" do
    test "names its class under type" do
      [error] = capture_errors(UnhandledError.exception(message: "no impl for me"))

      assert error.type == "internal_error"
      refute Map.has_key?(error, :code)
    end
  end

  describe "an exception whose protocol implementation raises" do
    test "names its class under type" do
      [error] = capture_errors(ExplodingError.exception(message: "boom"))

      assert error.type == "error"
      refute Map.has_key?(error, :code)
    end
  end

  describe "a domain with show_raised_errors? set" do
    test "names the exception's class under type" do
      [error] =
        Errors.to_errors(
          UnhandledError.exception(message: "shown to the client"),
          RaisingErrorsDomain,
          nil,
          nil,
          %{},
          %{rpc_dsl_section: :typescript_rpc}
        )

      assert error.type == "unknown_error"
      refute Map.has_key?(error, :code)
    end
  end

  describe "the protocol implementation the log tells a developer to write" do
    test "sets type, not code" do
      {_errors, log} =
        with_log(fn -> capture_errors(UnhandledError.exception(message: "no impl for me")) end)

      assert log =~ ~s(type: "error_type")
      refute log =~ ~s(code: "error_code")
    end
  end

  describe "every error the protocol builds" do
    test "carries type and never code" do
      errors = [
        Ash.Error.Query.NotFound.exception(resource: AshIntrospection.Test.Account),
        Ash.Error.Changes.InvalidAttribute.exception(field: :email, message: "is invalid"),
        Ash.Error.Query.InvalidArgument.exception(field: :filter, message: "is invalid"),
        Ash.Error.Invalid.InvalidPrimaryKey.exception(
          resource: AshIntrospection.Test.Account,
          value: "nope"
        )
      ]

      for error <- errors do
        result = ErrorProtocol.to_error(error)

        assert is_binary(result.type), "#{inspect(error.__struct__)} has no type"
        refute Map.has_key?(result, :code)
      end
    end
  end

  # `Ash.Error.to_error_class/1` turns a bare exception into an
  # `Ash.Error.Unknown.UnknownError`, which does implement the protocol.
  # Wrapping it in an Ash class first keeps the original struct intact, so the
  # protocol lookup finds no implementation — the path under test.
  defp capture_errors(error) do
    wrapped = Ash.Error.Invalid.exception(errors: [error])

    {errors, _log} = with_log(fn -> Errors.to_errors(wrapped, nil, nil, nil, %{}, %{}) end)

    errors
  end
end
