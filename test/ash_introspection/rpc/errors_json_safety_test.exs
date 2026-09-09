# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.ErrorsJsonSafetyTest do
  @moduledoc """
  An error's `vars` and `path` come from whatever built the error, so they can
  hold any Erlang term. The RPC payload is handed to a JSON encoder, which
  raises on anything it has no representation for - the request then dies at
  the encoder instead of returning the error.

  These tests pin the last step of the error pipeline: whatever reaches the
  client is JSON-encodable.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.Errors

  describe "values that already have a representation" do
    test "keeps binaries, numbers and booleans" do
      vars = vars_of(name: "Ada", count: 3, ratio: 1.5, active: true)

      assert vars[:name] == "Ada"
      assert vars[:count] == 3
      assert vars[:ratio] == 1.5
      assert vars[:active] == true
    end

    test "stringifies atoms" do
      assert vars_of(status: :archived)[:status] == "archived"
    end

    test "turns a tuple into a list" do
      assert vars_of(pair: {:timeout, 500})[:pair] == ["timeout", 500]
    end

    test "turns a keyword list into a map" do
      assert vars_of(opts: [retries: 2])[:opts] == %{"retries" => 2}
    end

    test "walks a nested map" do
      assert vars_of(limits: %{max: 10})[:limits] == %{max: 10}
    end

    test "renders dates and times as iso8601" do
      vars = vars_of(at: ~U[2026-02-14 01:02:03Z], on: ~D[2026-02-14])

      assert vars[:at] == "2026-02-14T01:02:03Z"
      assert vars[:on] == "2026-02-14"
    end

    test "renders a decimal as a plain string" do
      assert vars_of(amount: Decimal.new("10.50"))[:amount] == "10.50"
    end

    test "renders an Ash.CiString as its value" do
      assert vars_of(email: Ash.CiString.new("Ada@Example.com"))[:email] == "Ada@Example.com"
    end

    test "encodes the whole payload as JSON" do
      [response] = to_errors(error(vars: [pair: {:timeout, 500}, at: ~U[2026-02-14 01:02:03Z]]))

      assert is_binary(JSON.encode!(response))
    end
  end

  defp vars_of(vars) do
    [response] = to_errors(error(vars: vars))

    response.vars
  end

  defp error(opts) do
    [field: :profile, message: "invalid"]
    |> Keyword.merge(opts)
    |> Ash.Error.Changes.InvalidAttribute.exception()
  end

  defp to_errors(error), do: Errors.to_errors(error, nil, nil, nil, %{}, %{})
end
