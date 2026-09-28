# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.ErrorUnknownInputTest do
  @moduledoc """
  A request that names an input, a filter field, a sort field or a filter
  operator the resource does not have fails inside Ash. Before #113 none of
  those errors had an `Rpc.Error` implementation, so the client got
  `internal_error` and could not tell which key was wrong. Each test drives the
  request through Ash and `ErrorBuilder`, and round-trips the response through
  `Jason`, so it asserts what the client receives.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.ErrorBuilder
  alias AshIntrospection.Test.Policy.Memo

  require Ash.Query

  describe "an unknown input key on a create" do
    test "answers no_such_input and names the key" do
      error =
        Memo
        |> Ash.Changeset.for_create(:create, %{
          "bogus_key" => 1,
          "slug" => "a",
          "body" => "b",
          "owner_id" => "o"
        })
        |> Ash.create()
        |> error!()

      assert %{
               "type" => "no_such_input",
               "message" => "Unknown input %{field}",
               "short_message" => "Unknown input",
               "fields" => ["bogusKey"],
               "vars" => %{"field" => "bogusKey"}
             } = error

      refute_module_name(error)
    end
  end

  describe "an unknown filter field" do
    test "answers no_such_field and names the field" do
      error =
        Memo
        |> Ash.Query.filter_input(%{"bogus_field" => %{"eq" => 1}})
        |> Ash.read()
        |> error!()

      assert %{
               "type" => "no_such_field",
               "message" => "Unknown field %{field}",
               "short_message" => "Unknown field",
               "fields" => ["bogusField"],
               "vars" => %{"field" => "bogusField"},
               "path" => ["filter"]
             } = error

      refute_module_name(error)
    end
  end

  describe "an unknown filter operator" do
    test "answers no_such_filter_predicate and names the operator" do
      error =
        Memo
        |> Ash.Query.filter_input(%{"slug" => %{"bogus_op" => 1}})
        |> Ash.read()
        |> error!()

      assert %{
               "type" => "no_such_filter_predicate",
               "message" => "Unknown filter operator %{operator}",
               "short_message" => "Unknown filter operator",
               "vars" => %{"operator" => "bogusOp"},
               "path" => ["filter"]
             } = error

      refute_module_name(error)
    end
  end

  describe "an unknown sort field" do
    test "answers no_such_field and names the field" do
      error =
        Memo
        |> Ash.Query.sort_input("bogus_field")
        |> Ash.read()
        |> error!()

      assert %{
               "type" => "no_such_field",
               "fields" => ["bogusField"],
               "vars" => %{"field" => "bogusField"},
               "path" => ["sort"]
             } = error

      refute_module_name(error)
    end
  end

  describe "a multitenant request with no tenant" do
    test "answers tenant_required and names no resource" do
      error =
        Ash.Error.Invalid.TenantRequired.exception(resource: Memo)
        |> Ash.Error.to_error_class()
        |> error!()

      assert %{
               "type" => "tenant_required",
               "message" => "Tenant parameter is required",
               "short_message" => "Tenant required",
               "vars" => %{},
               "fields" => []
             } = error

      refute_module_name(error)
    end
  end

  defp error!({:error, error}), do: error!(error)

  defp error!(error) do
    [response] = List.wrap(ErrorBuilder.build_error_response(error))

    response |> Jason.encode!() |> Jason.decode!()
  end

  defp refute_module_name(error) do
    json = Jason.encode!(error)

    refute json =~ "Memo"
    refute json =~ "AshIntrospection"
    refute json =~ "Elixir."
  end
end
