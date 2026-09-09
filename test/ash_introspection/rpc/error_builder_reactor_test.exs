# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.ErrorBuilderReactorTest do
  @moduledoc """
  Pins the error payload a client receives from a Reactor-backed action.

  Reactor wraps whatever a step raises or returns in
  `%Reactor.Error.Invalid.RunStepError{error: inner}`. The wrapper is an
  exception, so `build_error_response/1` matched it on the generic Ash clause
  and reported the wrapper's own type and message — a step-execution notice
  naming a step the client has never heard of — instead of the validation error
  the step actually produced.

  `reactor` is a non-optional dependency of `ash` (`mix.lock`: `ash 3.33.1`
  requires `reactor ~> 1.0`), so the struct is always present and matching it
  at compile time costs nothing.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.ErrorBuilder

  describe "a Reactor step failure" do
    test "reports the inner Ash error, not the wrapper" do
      response =
        "email is not a valid address"
        |> invalid_changes()
        |> run_step_error()
        |> ErrorBuilder.build_error_response()

      assert [error] = response
      assert error.type == "invalid_changes"
      assert error.message =~ "email is not a valid address"
    end

    test "reports the inner error when it already arrives as an error class" do
      response =
        "email is not a valid address"
        |> invalid_changes()
        |> Ash.Error.to_error_class()
        |> run_step_error()
        |> ErrorBuilder.build_error_response()

      assert [error] = response
      assert error.type == "invalid_changes"
      assert error.message =~ "email is not a valid address"
    end

    test "keeps every sub-error of an inner error that carries several" do
      inner =
        Ash.Error.to_error_class([
          Ash.Error.Changes.Required.exception(field: :name),
          Ash.Error.Changes.Required.exception(field: :email)
        ])

      response = inner |> run_step_error() |> ErrorBuilder.build_error_response()

      assert length(response) == 2
      assert Enum.sort(Enum.flat_map(response, & &1.fields)) == ["email", "name"]
    end

    @tag capture_log: true
    test "falls back to a generic error when the inner error is not an Ash error" do
      response =
        RuntimeError.exception("boom")
        |> run_step_error()
        |> ErrorBuilder.build_error_response()

      assert [error] = response
      assert error.type == "unknown_error"
      refute error.message =~ "Run Step Error"
    end
  end

  defp invalid_changes(message) do
    Ash.Error.Changes.InvalidChanges.exception(message: message)
  end

  defp run_step_error(inner) do
    Reactor.Error.Invalid.RunStepError.exception(
      error: inner,
      step: %Reactor.Step{name: :validate_email}
    )
  end
end
