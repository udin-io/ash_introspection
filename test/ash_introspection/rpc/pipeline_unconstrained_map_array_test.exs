# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineUnconstrainedMapArrayTest do
  @moduledoc """
  Pins that a generic action returning an unconstrained `{:array, :map}` hands
  every one of its maps to the client untouched.

  This is #64, the sibling of #62 one type shape over. `unconstrained_map_action?/1`
  named `Ash.Type.Map` only, so an action returning `{:array, :map}` — which
  Ash normalises to `{:array, Ash.Type.Map}` with
  `[items: [preserve_nil_values?: false]]` — fell through to the typed path.
  That path has no field definitions to select against, so it wrote `nil` for
  every requested name the caller's maps do not use. Measured on `main` at
  `51a9c27` with an extraction template of `[:id, :name]`:

      [%{"_id" => "a-1", "name" => "KSR"}]  ->  [%{id: nil, name: "KSR"}]

  `_id` is gone and `id` is `nil` — silent data loss, not a re-keying nit.

  The array's meaningful constraints live under `:items`, so the guard has to
  unwrap the tuple and ask `has_field_constraints?/1` about the inner keyword
  list. Asking about `:fields` rather than comparing a whole keyword list
  against a literal is the #62 lesson; `CLAUDE.md` carries it and a grep keeps
  it.

  `:typed_rows` is the control: the same `{:array, :map}` shape carrying real
  `items: [fields: ...]` constraints, which must keep going through the typed
  path and keep being formatted.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.LedgerEntry
  alias AshIntrospection.Test.ListOutputDomain
  alias AshIntrospection.TypeSystem.Introspection

  @raw_rows [
    %{"_id" => "a-1", "name" => "KSR", "nested" => %{"_rev" => "rev-1"}},
    %{"_id" => "a-2", "name" => "Ivy", "nested" => %{"_rev" => "rev-2"}}
  ]

  defp response(action_name, extraction_template) do
    request =
      %{
        domain: ListOutputDomain,
        resource: LedgerEntry,
        action: Ash.Resource.Info.action(LedgerEntry, action_name),
        rpc_action: %{},
        input: %{},
        context: %{},
        select: [],
        load: [],
        extraction_template: extraction_template,
        show_metadata: []
      }
      |> Request.new()

    {:ok, ash_result} = Pipeline.execute_ash_action(request)
    {:ok, processed} = Pipeline.process_result(ash_result, request)

    Pipeline.format_output_with_request(%{success: true, data: processed}, request)
  end

  describe "the premise" do
    test "ash normalises an array-of-map action to a tuple type with :items constraints" do
      action = Ash.Resource.Info.action(LedgerEntry, :raw_rows)

      assert action.returns == {:array, Ash.Type.Map}
      assert action.constraints == [items: [preserve_nil_values?: false]]
      refute Introspection.has_field_constraints?(action.constraints)
      refute Introspection.has_field_constraints?(Keyword.get(action.constraints, :items))
    end

    test "a constrained array-of-map does carry :fields under :items" do
      action = Ash.Resource.Info.action(LedgerEntry, :typed_rows)

      assert Introspection.has_field_constraints?(Keyword.get(action.constraints, :items))
    end
  end

  describe "a generic action returning an unconstrained array of maps" do
    test "hands every row back whole when the client asks for names they do not carry" do
      assert %{"data" => @raw_rows, "success" => true} = response(:raw_rows, [:id, :name])
    end

    test "writes no nil into any row" do
      %{"data" => rows} = response(:raw_rows, [:id, :name])

      assert [first, second] = rows
      assert first["_id"] == "a-1"
      assert first["name"] == "KSR"
      assert second["_id"] == "a-2"
      assert second["name"] == "Ivy"
      refute Enum.any?(rows, &Map.has_key?(&1, :id))
      refute Enum.any?(rows, &Enum.any?(&1, fn {_key, value} -> is_nil(value) end))
    end

    test "keeps the caller's keys in every row, leading underscore included" do
      %{"data" => rows} = response(:raw_rows, [:id, :name])

      for row <- rows do
        assert Enum.sort(Map.keys(row)) == ["_id", "name", "nested"]
      end
    end

    test "leaves nested keys alone in every row" do
      %{"data" => rows} = response(:raw_rows, [:id, :name])

      assert Enum.map(rows, & &1["nested"]) == [%{"_rev" => "rev-1"}, %{"_rev" => "rev-2"}]
    end

    test "hands the rows back when the client asks for the maps' own keys" do
      assert %{"data" => @raw_rows} = response(:raw_rows, [:_id, :name, :nested])
    end

    test "hands the rows back when the client asks for nothing" do
      assert %{"data" => @raw_rows} = response(:raw_rows, [])
    end
  end

  describe "a generic action returning a constrained array of maps" do
    test "still goes through the typed path and formats every row" do
      %{"data" => rows} = response(:typed_rows, [:row_id, :row_label])

      assert rows == [
               %{"rowId" => "t-1", "rowLabel" => "first"},
               %{"rowId" => "t-2", "rowLabel" => "second"}
             ]
    end
  end
end
