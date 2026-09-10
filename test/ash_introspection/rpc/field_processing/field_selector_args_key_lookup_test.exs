# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.FieldProcessing.FieldSelectorArgsKeyLookupTest do
  @moduledoc """
  Issue #45: `get_args_and_fields/1` read its two keys with
  `Map.get(map, :args) || Map.get(map, "args")`, the shape that made #15 a
  data-corruption bug. `||` cannot tell a key that is present and falsy from a
  key that is absent.

  For data the issue's "latent" verdict holds: `:args` is a map and `:fields`
  is a list, and neither `%{}` nor `[]` is falsy, so no well-formed request
  loses a value. The idiom is not inert, though. `||` returns its *right*
  operand when both sides are falsy, so a present-and-`false` value survives
  under the string key and is erased under the atom key. Measured on `main` at
  `b99e5a3` against `Test.LoadRestrictions.Article`, whose `:slug` calculation
  takes no arguments and returns a plain string:

      %{"slug" => %{fields: false}}     -> {:ok, ...}   loaded, selection dropped
      %{"slug" => %{"fields" => false}} -> {:error, {:invalid_field_selection,
                                            :slug, :calculation, []}}

  One request, two answers, decided by which key form the caller happened to
  build. Both forms reach here — the atom form is why `atomize_nested_value/3`
  carries `%{args: _}` and `%{fields: _}` clauses alongside the string ones.

  `Map.fetch/2` before falling back to the string key answers presence rather
  than truthiness, in the style of `plain_map_field/2` in `ResultProcessor`.
  The two spellings now agree everywhere: `fields: false` is rejected under
  both, and `args: false` takes the with-args path under both and is handed to
  Ash as written, which is what the string form already did.

  `nil` keeps its own meaning. A JSON `null` under `:args` says "no
  arguments", not "arguments I could not name", so the `not is_nil/1` guard
  stays and those two cases answer exactly as they did before.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.FieldProcessing.FieldSelector
  alias AshIntrospection.Test.LoadRestrictions.Article

  defp process(fields), do: FieldSelector.process(Article, :read, fields)

  describe "a well-formed request is untouched" do
    test "a calculation with arguments still loads with its arguments" do
      assert {:ok, {[:id], [prefixed_title: %{"prefix" => "re: "}], [:id, :prefixed_title]}} =
               process(["id", %{"prefixedTitle" => %{"args" => %{"prefix" => "re: "}}}])
    end

    test "the atom key form gives the same answer as the string key form" do
      assert process(["id", %{"prefixedTitle" => %{"args" => %{"prefix" => "re: "}}}]) ==
               process(["id", %{"prefixedTitle" => %{args: %{"prefix" => "re: "}}}])
    end

    test "an empty :args alongside :fields still resolves both" do
      assert {:ok, {[:id], [computed_meta: {%{}, [:label]}], [:id, {:computed_meta, [:label]}]}} =
               process(["id", %{"computedMeta" => %{"args" => %{}, "fields" => ["label"]}}])
    end

    test "a bare :fields selection still resolves" do
      assert {:ok, {[:id], [computed_meta: [:label]], [:id, {:computed_meta, [:label]}]}} =
               process(["id", %{"computedMeta" => %{"fields" => ["label"]}}])
    end

    test "a map naming neither key is not read as a calculation envelope" do
      # `:not_args_structure`, so the map goes down the nested-field path and
      # fails there — not with an argument error.
      assert {:error, {:unsupported_field_combination, :relationship, :computed_meta, _, []}} =
               process(["id", %{"computedMeta" => %{"label" => nil}}])
    end
  end

  describe "a key that is present and falsy" do
    test "an atom-keyed :fields is read as present, not as absent" do
      assert {:error, {:invalid_field_selection, :slug, :calculation, []}} =
               process(["id", %{"slug" => %{fields: false}}])
    end

    test "both key forms of :fields give the same answer" do
      assert process(["id", %{"slug" => %{fields: false}}]) ==
               process(["id", %{"slug" => %{"fields" => false}}])
    end

    test "both key forms of :args give the same answer" do
      assert process(["id", %{"prefixedTitle" => %{args: false}}]) ==
               process(["id", %{"prefixedTitle" => %{"args" => false}}])
    end

    test "an atom-keyed :args is read as present, not as absent" do
      assert {:ok, {[:id], [prefixed_title: false], [:id, :prefixed_title]}} =
               process(["id", %{"prefixedTitle" => %{args: false}}])
    end
  end

  describe "an explicit null keeps its old meaning" do
    test "a null :args is not a with-args request" do
      assert {:error, {:invalid_calculation_args, :slug, []}} =
               process(["id", %{"slug" => %{"args" => nil}}])
    end

    test "a null :fields on a plain calculation loads it plainly" do
      assert {:ok, {[:id], [:slug], [:id, :slug]}} =
               process(["id", %{"slug" => %{"fields" => nil}}])
    end
  end
end
