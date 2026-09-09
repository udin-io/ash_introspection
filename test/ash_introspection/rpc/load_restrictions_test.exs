# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.LoadRestrictionsTest do
  @moduledoc """
  The restriction algebra on its own, before anything calls it (issue #19).
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.LoadRestrictions

  doctest AshIntrospection.Rpc.LoadRestrictions

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
end
