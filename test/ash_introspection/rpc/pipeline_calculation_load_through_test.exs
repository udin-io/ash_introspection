# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineCalculationLoadThroughTest do
  @moduledoc """
  Pins that a client can select fields of a calculation returning a composite
  value, and gets exactly those fields back, camelCased. #25.

  Measured on `main` at `3429006`: `FieldSelector` emitted `{calc, fields}`
  for every calculation returning an embedded resource, a `:struct` of a
  resource, an array of either, or a union. Ash rejects that shape for a
  calculation (`InvalidLoad`, or `NoSuchInput` for a union), so the whole
  request failed and the client got no data. Ash takes
  `{calc, {args, fields}}` instead. A typed map is the opposite: Ash cannot
  load through it, so it keeps the bare name.

  No test drove one of these through `Pipeline` before: the selection tests
  assert `FieldSelector`'s output, which cannot see a load Ash rejects.
  """
  use ExUnit.Case, async: true

  import AshIntrospection.Test.LoadThrough, only: [rpc: 1, seed!: 0]

  setup do
    seed!()
    :ok
  end

  describe "a calculation returning an embedded resource" do
    test "returns the selected attribute and nothing else" do
      assert {:ok, [%{"topTag" => %{"displayName" => "Top name"}} = owner]} =
               rpc([%{"topTag" => ["displayName"]}])

      assert Map.keys(owner["topTag"]) == ["displayName"]
    end

    test "loads through to the embedded resource's own calculation" do
      assert {:ok, [%{"topTag" => top_tag}]} = rpc([%{"topTag" => ["displayName", "shout"]}])
      assert top_tag == %{"displayName" => "Top name", "shout" => "TOP"}
    end

    test "an envelope with fields and no args returns the same" do
      assert rpc([%{"topTag" => %{"fields" => ["displayName"]}}]) ==
               rpc([%{"topTag" => ["displayName"]}])
    end

    test "an envelope with empty args and fields loads through the same way" do
      assert rpc([%{"topTag" => %{"args" => %{}, "fields" => ["displayName", "shout"]}}]) ==
               {:ok, [%{"topTag" => %{"displayName" => "Top name", "shout" => "TOP"}}]}
    end
  end

  describe "a calculation returning a :struct of a resource" do
    test "returns the selected attribute and calculation" do
      assert {:ok, [%{"bestItem" => best_item}]} = rpc([%{"bestItem" => ["name", "loudName"]}])
      assert best_item == %{"name" => "best", "loudName" => "BEST"}
    end
  end

  describe "a calculation returning an array of embedded resources" do
    test "returns the selected fields on every element" do
      assert {:ok, [%{"allTags" => all_tags}]} = rpc([%{"allTags" => ["displayName", "shout"]}])

      assert all_tags == [
               %{"displayName" => "One name", "shout" => "ONE"},
               %{"displayName" => "Two name", "shout" => "TWO"}
             ]
    end
  end

  describe "a calculation returning a union" do
    test "returns the selected fields of the member" do
      assert {:ok, [%{"pick" => pick}]} =
               rpc([%{"pick" => [%{"tag" => ["displayName", "shout"]}]}])

      assert pick == %{"tag" => %{"displayName" => "Picked name", "shout" => "PICKED"}}
    end
  end

  describe "a calculation returning a typed map" do
    test "returns the selected field only" do
      assert {:ok, [%{"stats" => %{"label" => "stats"} = stats}]} = rpc([%{"stats" => ["label"]}])
      assert Map.keys(stats) == ["label"]
    end
  end
end
