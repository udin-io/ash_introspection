# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.ResultProcessorRedactionTest do
  @moduledoc """
  Guards the untemplated result path against disclosing values the actor was
  denied.

  `%Ash.ForbiddenField{}` carries the real value in `original_value` and hides
  it only from `Inspect`, so any code that walks the struct's fields will
  serialize the secret. These tests assert on what the client would actually
  receive.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Rpc.ResultProcessor

  @secret "123-45-6789"

  defmodule Envelope do
    @moduledoc false
    defstruct [:label, :payload]
  end

  describe "normalize_primitive/1 with a forbidden field" do
    test "redacts a bare forbidden field to nil" do
      assert nil == ResultProcessor.normalize_primitive(forbidden(:ssn))
    end

    test "redacts a forbidden field nested in a plain struct" do
      result =
        ResultProcessor.normalize_primitive(%Envelope{label: "user", payload: forbidden(:ssn)})

      assert %{label: "user", payload: nil} == result
    end

    test "redacts a forbidden field nested in an Ash resource struct" do
      user = struct(AshIntrospection.Test.User, %{name: "Ada", email: forbidden(:email)})

      result = ResultProcessor.normalize_primitive(user)

      assert %{name: "Ada", email: nil} = result
      refute leaks_secret?(result)
    end

    test "redacts a forbidden field nested in a plain map" do
      result = ResultProcessor.normalize_primitive(%{name: "Ada", ssn: forbidden(:ssn)})

      assert %{name: "Ada", ssn: nil} == result
    end

    test "redacts a forbidden field nested in a list" do
      assert [nil, "Ada"] == ResultProcessor.normalize_primitive([forbidden(:ssn), "Ada"])
    end

    test "redacts a forbidden field nested in a keyword list" do
      result = ResultProcessor.normalize_primitive(name: "Ada", ssn: forbidden(:ssn))

      assert %{"name" => "Ada", "ssn" => nil} == result
    end
  end

  describe "normalize_primitive/1 with a not-loaded field" do
    test "redacts a bare not-loaded field to nil" do
      assert nil == ResultProcessor.normalize_primitive(not_loaded(:address))
    end

    test "omits a not-loaded field nested in a plain struct" do
      result =
        ResultProcessor.normalize_primitive(%Envelope{
          label: "user",
          payload: not_loaded(:payload)
        })

      assert %{label: "user"} == result
    end

    test "omits a not-loaded field nested in an Ash resource struct" do
      user = struct(AshIntrospection.Test.User, %{name: "Ada", email: not_loaded(:email)})

      result = ResultProcessor.normalize_primitive(user)

      assert "Ada" == result.name
      refute Map.has_key?(result, :email)
    end

    test "omits a not-loaded field nested in a plain map" do
      result = ResultProcessor.normalize_primitive(%{name: "Ada", address: not_loaded(:address)})

      assert %{name: "Ada"} == result
    end
  end

  describe "process/4 without an extraction template" do
    test "does not leak the value behind a forbidden field" do
      user = struct(AshIntrospection.Test.User, %{name: "Ada", email: forbidden(:email)})

      result = ResultProcessor.process(user, [], AshIntrospection.Test.User, %{})

      refute leaks_secret?(result)
    end
  end

  describe "Pipeline.process_result/3 for an unconstrained map action" do
    test "redacts a forbidden field in the returned map" do
      {:ok, result} = Pipeline.process_result(%{"ssn" => forbidden(:ssn)}, map_action_request())

      assert %{"ssn" => nil} == result
    end

    test "redacts a forbidden field nested below the returned map" do
      raw = %{"user" => %Envelope{label: "Ada", payload: forbidden(:ssn)}}

      {:ok, result} = Pipeline.process_result(raw, map_action_request())

      assert %{"user" => %{label: "Ada", payload: nil}} == result
    end

    test "omits a not-loaded field in the returned map" do
      {:ok, result} =
        Pipeline.process_result(%{"address" => not_loaded(:address)}, map_action_request())

      assert %{} == result
    end
  end

  defp map_action_request do
    Request.new(%{
      action: %{type: :action, returns: Ash.Type.Map, constraints: []},
      extraction_template: [],
      show_metadata: []
    })
  end

  defp forbidden(field) do
    %Ash.ForbiddenField{field: field, type: :attribute, original_value: @secret}
  end

  defp not_loaded(field) do
    %Ash.NotLoaded{field: field, type: :attribute}
  end

  defp leaks_secret?(value) when is_binary(value), do: String.contains?(value, @secret)
  defp leaks_secret?(%_{} = value), do: value |> Map.from_struct() |> leaks_secret?()

  defp leaks_secret?(value) when is_map(value) do
    Enum.any?(value, fn {key, val} -> leaks_secret?(key) or leaks_secret?(val) end)
  end

  defp leaks_secret?(value) when is_list(value), do: Enum.any?(value, &leaks_secret?/1)
  defp leaks_secret?(_value), do: false
end
