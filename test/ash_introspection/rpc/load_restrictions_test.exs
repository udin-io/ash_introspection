# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.LoadRestrictionsTest do
  @moduledoc """
  Load restrictions shape which relationships, calculations and aggregates an
  action will load for a client (issue #19). Everything here goes through
  `FieldSelector.process/4`, the function a generator calls, because the
  guarantee being tested is about the load statement that comes out of field
  selection, not about the shape of any one private function.

  The fixtures live in `test/support/load_restriction_resources.ex` and carry
  one field of every category that appends to the load statement, so every one
  of the six append sites is exercised from here. Four of them can be made to
  refuse; the two that only fire when a nested selection already produced a
  load cannot, because that nested load passed the check one level deeper —
  see the note on those sites in `FieldSelector`.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.ErrorBuilder
  alias AshIntrospection.Rpc.FieldProcessing.FieldSelector
  alias AshIntrospection.Rpc.LoadRestrictions
  alias AshIntrospection.Test.LoadRestrictions.Article

  doctest AshIntrospection.Rpc.LoadRestrictions

  defp process(fields, config \\ %{}) do
    FieldSelector.process(Article, :read, fields, config)
  end

  defp deny(spec), do: %{load_restrictions: {:deny, spec}}
  defp allow(spec), do: %{load_restrictions: {:allow, spec}}

  # Every field shape that reaches an append site, so the compatibility test
  # below covers all six of them at once.
  @every_load_shape [
    ["id", "slug"],
    ["id", %{"author" => ["id", "articleCount"]}],
    ["id", %{"meta" => ["label", "shout"]}],
    ["id", %{"comments" => ["id", "body"]}],
    ["id", %{"comments" => ["id", "score"]}],
    ["id", %{"computedMeta" => ["label"]}],
    ["id", %{"prefixedTitle" => %{"args" => %{"prefix" => "re: "}}}],
    ["id", %{"extra" => [%{"meta" => ["label", "shout"]}]}]
  ]

  describe "omitting the config key" do
    test "leaves every load shape exactly as it was" do
      for fields <- @every_load_shape do
        assert process(fields) == process(fields, %{load_restrictions: :none})
      end
    end

    test "an empty config loads what was asked for" do
      assert {:ok, {[:id], [comments: [:id, :score]], _}} =
               process(["id", %{"comments" => ["id", "score"]}])

      assert {:ok, {[:id], [:slug], _}} = process(["id", "slug"])

      assert {:ok, {[:id], [author: [:id, :article_count]], _}} =
               process(["id", %{"author" => ["id", "articleCount"]}])
    end

    test "an unrecognized restriction value is treated as no restriction" do
      assert process(["id", "slug"], %{load_restrictions: :everything}) ==
               process(["id", "slug"])
    end
  end

  describe "denied_loads" do
    test "refuses a denied relationship and names it" do
      assert {:error, {:load_denied, ["comments"]}} =
               process(["id", %{"comments" => ["id", "body"]}], deny([:comments]))
    end

    test "refuses a denied calculation at the root" do
      assert {:error, {:load_denied, ["slug"]}} = process(["id", "slug"], deny([:slug]))
    end

    test "still loads what is not denied" do
      assert {:ok, {[:id], [:slug], _}} = process(["id", "slug"], deny([:comments]))
    end

    test "denies everything under a denied field" do
      assert {:error, {:load_denied, ["comments.score"]}} =
               process(["id", %{"comments" => ["id", "score"]}], deny([:comments]))
    end

    test "a nested deny leaves the parent loadable" do
      config = deny(comments: [:score])

      assert {:ok, {[:id], [comments: [:id, :body]], _}} =
               process(["id", %{"comments" => ["id", "body"]}], config)

      assert {:error, {:load_denied, ["comments.score"]}} =
               process(["id", %{"comments" => ["id", "score"]}], config)
    end

    test "attributes are never restricted" do
      assert {:ok, {[:id, :title], [], _}} = process(["id", "title"], deny([:title]))
    end
  end

  describe "allowed_loads" do
    test "loads an allowed relationship" do
      assert {:ok, {[:id], [comments: [:id, :body]], _}} =
               process(["id", %{"comments" => ["id", "body"]}], allow([:comments]))
    end

    test "refuses a load that is not on the list" do
      assert {:error, {:load_not_allowed, ["slug"]}} =
               process(["id", "slug"], allow([:comments]))
    end

    test "allowing a parent does not allow its children" do
      assert {:error, {:load_not_allowed, ["comments.score"]}} =
               process(["id", %{"comments" => ["id", "score"]}], allow([:comments]))
    end

    test "naming a nested path allows the parent needed to reach it" do
      config = allow(comments: [:score])

      assert {:ok, {[:id], [comments: [:id, :score]], _}} =
               process(["id", %{"comments" => ["id", "score"]}], config)

      assert {:ok, {[:id], [comments: [:id, :body]], _}} =
               process(["id", %{"comments" => ["id", "body"]}], config)
    end

    test "a sibling of an allowed nested path is still refused" do
      assert {:error, {:load_not_allowed, ["author"]}} =
               process(["id", %{"author" => ["id", "name"]}], allow(comments: [:score]))
    end
  end

  describe "every category that appends to the load statement" do
    test "a root calculation" do
      assert {:error, {:load_denied, ["slug"]}} = process(["id", "slug"], deny([:slug]))
    end

    test "an aggregate reached through a relationship" do
      assert {:error, {:load_denied, ["author.article_count"]}} =
               process(
                 ["id", %{"author" => ["id", "articleCount"]}],
                 deny(author: [:article_count])
               )
    end

    # The embedded attribute only appends when its own selection produced a
    # load, and that load was already checked one level deeper, so the deeper
    # path is the one reported. See the note on the append site itself.
    test "a calculation inside an embedded attribute" do
      assert {:error, {:load_denied, ["meta.shout"]}} =
               process(["id", %{"meta" => ["label", "shout"]}], deny([:meta]))

      assert {:error, {:load_denied, ["meta.shout"]}} =
               process(["id", %{"meta" => ["label", "shout"]}], deny(meta: [:shout]))
    end

    test "a relationship" do
      assert {:error, {:load_denied, ["comments"]}} =
               process(["id", %{"comments" => ["id", "body"]}], deny([:comments]))
    end

    test "a calculation returning an embedded resource" do
      assert {:error, {:load_denied, ["computed_meta"]}} =
               process(["id", %{"computedMeta" => ["label"]}], deny([:computed_meta]))
    end

    test "a calculation with arguments" do
      assert {:error, {:load_denied, ["prefixed_title"]}} =
               process(
                 ["id", %{"prefixedTitle" => %{"args" => %{"prefix" => "re: "}}}],
                 deny([:prefixed_title])
               )
    end

    test "a calculation inside a union member" do
      assert {:error, {:load_denied, ["extra.meta.shout"]}} =
               process(
                 ["id", %{"extra" => [%{"meta" => ["label", "shout"]}]}],
                 deny(extra: [:meta])
               )

      assert {:ok, {[:id, :extra], [extra: [meta: [:shout]]], _}} =
               process(["id", %{"extra" => [%{"meta" => ["label", "shout"]}]}], deny([:comments]))
    end
  end

  describe "nesting depth" do
    test "a path is checked at each level, not only the first" do
      # comments is allowed outright, so only the second level can refuse this.
      assert {:error, {:load_not_allowed, ["comments.score"]}} =
               process(["id", %{"comments" => ["id", "score"]}], allow([:comments]))
    end

    test "the reported path is the full path, not the leaf" do
      assert {:error, {:load_denied, [path]}} =
               process(["id", %{"author" => ["id", "articleCount"]}], deny([:author]))

      assert path == "author.article_count"
    end
  end

  describe "normalize/1" do
    test "expands a flat spec" do
      assert LoadRestrictions.normalize({:deny, [:comments]}) == {:deny, [[:comments]]}
    end

    test "expands a nested spec to full paths and not to the parent" do
      assert LoadRestrictions.normalize({:allow, [comments: [:score], author: [:article_count]]}) ==
               {:allow, [[:comments, :score], [:author, :article_count]]}
    end

    test "anything else is :none" do
      assert LoadRestrictions.normalize(:none) == :none
      assert LoadRestrictions.normalize(nil) == :none
      assert LoadRestrictions.normalize({:allow_maybe, [:comments]}) == :none
    end

    test "is idempotent" do
      spec = {:deny, [:comments, [author: [:article_count]]]}
      once = LoadRestrictions.normalize(spec)

      assert LoadRestrictions.normalize(once) == once
    end
  end

  describe "check!/2" do
    test ":none permits any path" do
      assert LoadRestrictions.check!([:anything, :at, :all], :none) == :ok
    end

    test "a denied path throws, naming the dotted path" do
      restrictions = LoadRestrictions.normalize({:deny, [comments: [:score]]})

      assert catch_throw(LoadRestrictions.check!([:comments, :score], restrictions)) ==
               {:load_denied, ["comments.score"]}

      assert LoadRestrictions.check!([:comments], restrictions) == :ok
    end

    test "a deny inherits downwards" do
      restrictions = LoadRestrictions.normalize({:deny, [:comments]})

      assert catch_throw(LoadRestrictions.check!([:comments, :score], restrictions)) ==
               {:load_denied, ["comments.score"]}
    end

    test "an allow does not inherit downwards, but does reach upwards" do
      restrictions = LoadRestrictions.normalize({:allow, [comments: [:score]]})

      assert LoadRestrictions.check!([:comments], restrictions) == :ok
      assert LoadRestrictions.check!([:comments, :score], restrictions) == :ok

      assert catch_throw(LoadRestrictions.check!([:comments, :body], restrictions)) ==
               {:load_not_allowed, ["comments.body"]}

      assert catch_throw(LoadRestrictions.check!([:author], restrictions)) ==
               {:load_not_allowed, ["author"]}
    end
  end

  describe "the error payload" do
    test "names the refused path so a client can fix the request" do
      {:error, error} =
        process(["id", %{"comments" => ["id", "score"]}], deny(comments: [:score]))

      assert %{type: "load_denied", fields: ["comments.score"], vars: %{fields: "comments.score"}} =
               ErrorBuilder.build_error_response(error)
    end

    test "distinguishes a load that is not allowed from one that is denied" do
      {:error, error} = process(["id", "slug"], allow([:comments]))

      assert %{type: "load_not_allowed", fields: ["slug"]} =
               ErrorBuilder.build_error_response(error)
    end
  end
end
