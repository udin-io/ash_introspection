# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineNestedAggregateTest do
  @moduledoc """
  Pins field selection on a `first` or `list` aggregate over an embedded
  resource or a union. #25.

  Measured on `main` at `3429006`: `FieldSelector` refused every nested
  selection on an aggregate with `invalid_field_selection`, and the same
  aggregate asked flat came back whole, with snake_case keys. Both came from
  one cause: `agg.type` is `nil` for `first` and `list`, so no stage knew the
  value was a `Tag`.

  Ash cannot load through an aggregate, so the selection only filters the
  value. Below the aggregate a client may name attributes only; a calculation
  there is an unknown field.

  A flat request for such an aggregate is refused with
  `requires_field_selection`, the same answer as an embedded attribute. The
  owner chose that on #25 (option A); it breaks a client that asked flat.
  """
  use ExUnit.Case, async: true

  import AshIntrospection.Test.LoadThrough, only: [rpc: 1, rpc: 2, seed!: 0, seed_empty!: 0]

  setup do
    seed!()
    :ok
  end

  describe "a first aggregate over an embedded resource" do
    test "returns the selected attribute and nothing else" do
      assert rpc([%{"firstTag" => ["displayName"]}]) ==
               {:ok, [%{"firstTag" => %{"displayName" => "Red"}}]}
    end

    test "is null when there is no related record" do
      seed_empty!()

      assert {:ok, owners} = rpc(["name", %{"firstTag" => ["displayName"]}])

      assert Enum.sort_by(owners, & &1["name"]) == [
               %{"name" => "a", "firstTag" => %{"displayName" => "Red"}},
               %{"name" => "b", "firstTag" => nil}
             ]
    end

    test "refuses a calculation below it as an unknown field" do
      assert {:error, %{type: "unknown_field", fields: ["firstTag.shout"]}} =
               rpc([%{"firstTag" => ["shout"]}])
    end

    test "refuses a calculation envelope below it as an unknown field" do
      assert {:error, %{type: "unknown_field", fields: ["firstTag.shout"]}} =
               rpc([%{"firstTag" => [%{"shout" => %{"args" => %{}}}]}])
    end

    test "is refused when its load is denied" do
      assert {:error, %{type: "load_denied", fields: ["first_tag"]}} =
               rpc([%{"firstTag" => ["displayName"]}], %{
                 load_restrictions: {:deny, [:first_tag]}
               })
    end

    test "asked flat, requires a field selection" do
      assert {:error, %{type: "requires_field_selection", fields: ["firstTag"]}} =
               rpc(["firstTag"])
    end
  end

  describe "a first aggregate over a union" do
    test "returns the selected attribute of the member" do
      assert rpc([%{"firstExtra" => [%{"tag" => ["displayName"]}]}]) ==
               {:ok, [%{"firstExtra" => %{"tag" => %{"displayName" => "Blue"}}}]}
    end

    test "asked flat, requires a field selection" do
      assert {:error, %{type: "requires_field_selection", fields: ["firstExtra"]}} =
               rpc(["firstExtra"])
    end
  end

  describe "a list aggregate over an embedded resource" do
    test "returns the selected attribute on every element" do
      assert rpc([%{"allItemTags" => ["displayName"]}]) ==
               {:ok,
                [%{"allItemTags" => [%{"displayName" => "Red"}, %{"displayName" => "Green"}]}]}
    end

    test "asked flat, requires a field selection" do
      assert {:error, %{type: "requires_field_selection", fields: ["allItemTags"]}} =
               rpc(["allItemTags"])
    end
  end

  describe "a scalar aggregate" do
    test "a first aggregate asked flat returns its value" do
      assert rpc(["firstName"]) == {:ok, [%{"firstName" => "i1"}]}
    end

    test "a first aggregate refuses a nested selection" do
      assert {:error, %{type: "invalid_field_selection", fields: ["firstName"]}} =
               rpc([%{"firstName" => ["length"]}])
    end

    test "a count asked flat returns its value" do
      assert rpc(["itemCount"]) == {:ok, [%{"itemCount" => 2}]}
    end
  end
end
