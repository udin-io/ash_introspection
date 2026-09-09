# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.ResultProcessorPlainMapTest do
  @moduledoc """
  Pins the untyped-map extraction path against a `false` field arriving at the
  client as `nil`.

  `Map.get(map, :field) || Map.get(map, "field")` cannot tell a field that is
  present and `false` from one that is absent: a falsy left side always hands
  the lookup to the string key, so a legitimate `false` is reported as `nil`.
  `Map.fetch/2` separates the three cases a client cares about — present and
  `false`, present and `nil`, absent — and these tests drive all three through
  `ResultProcessor.process/4`, the value the client actually receives.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.ResultProcessor

  describe "untyped map fields" do
    test "a field present and false stays false" do
      assert %{enabled: false} == ResultProcessor.process(%{enabled: false}, [:enabled])
    end

    test "a field present and false under a string key stays false" do
      assert %{enabled: false} == ResultProcessor.process(%{"enabled" => false}, [:enabled])
    end

    test "an atom key holding false wins over a string key holding true" do
      # The discriminator: `||` returns the string key's `true` here, so a test
      # that only asserts `false` on a single-key map would pass a sloppy fix.
      assert %{enabled: false} ==
               ResultProcessor.process(%{:enabled => false, "enabled" => true}, [:enabled])
    end

    test "a field present and nil stays nil rather than falling back to the string key" do
      assert %{enabled: nil} ==
               ResultProcessor.process(%{:enabled => nil, "enabled" => true}, [:enabled])
    end

    test "an absent atom key still falls back to the string key" do
      assert %{count: 3} == ResultProcessor.process(%{"count" => 3}, [:count])
    end

    test "a field absent from both key forms is nil" do
      assert %{enabled: nil} == ResultProcessor.process(%{other: 1}, [:enabled])
    end
  end

  describe "untyped map fields under a nested template" do
    test "a nested field present and false stays false" do
      assert %{settings: %{enabled: false}} ==
               ResultProcessor.process(%{settings: %{enabled: false}}, [{:settings, [:enabled]}])
    end

    test "an atom key holding false wins over a string key holding a nested map" do
      assert %{settings: false} ==
               ResultProcessor.process(
                 %{:settings => false, "settings" => %{enabled: true}},
                 [{:settings, [:enabled]}]
               )
    end

    test "a nested atom key holding nil stays nil rather than falling back" do
      assert %{settings: nil} ==
               ResultProcessor.process(
                 %{:settings => nil, "settings" => %{enabled: true}},
                 [{:settings, [:enabled]}]
               )
    end

    test "an absent nested atom key still falls back to the string key" do
      assert %{settings: %{enabled: true}} ==
               ResultProcessor.process(%{"settings" => %{enabled: true}}, [
                 {:settings, [:enabled]}
               ])
    end
  end
end
