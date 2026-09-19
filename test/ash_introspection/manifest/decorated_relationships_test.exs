# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Manifest.DecoratedRelationshipsTest do
  @moduledoc """
  Every relationship is decorated, private ones included, and
  `AshIntrospection.ResourceInfo.relationship/3` answers from the decoration.

  A generated manifest cannot answer this question on its own.
  `Ash.Info.Manifest.Generator.generate/1` defaults
  `:include_private_relationships?` to `false`
  (`deps/ash/lib/ash/info/manifest/generator/resource_builder.ex:271`) and
  `%Ash.Info.Manifest{}` records no build options
  (`deps/ash/lib/ash/info/manifest.ex:40`), so a reader holding a manifest
  cannot tell a resource with no private relationships from a manifest built
  without them. The decorator settles it: it lists relationships live, at
  compile time, so the decoration is complete whatever the manifest was built
  with.

  Which is why the tests below tamper. `AshIntrospection.Manifest.Decorator`
  captures the live structs, so the decoration and `Ash.Resource.Info` agree by
  construction and a parity assertion passes against a reader that never opened
  the manifest — the failure `CLAUDE.md` records against stage 4. A tampered
  destination separates the two.
  """

  use ExUnit.Case, async: true

  alias AshIntrospection.Manifest.Custom
  alias AshIntrospection.ResourceInfo
  alias AshIntrospection.Test
  alias AshIntrospection.Test.ManifestFixture

  @default_namespace Custom.default_namespace()

  defp resources, do: ManifestFixture.resource_modules()

  defp decorated_config, do: ManifestFixture.decorated_config()

  defp decoration(module) do
    {resource, @default_namespace} = ResourceInfo.decoration(module, decorated_config())
    resource
  end

  defp record(relationship) do
    %{
      name: relationship.name,
      destination: relationship.destination,
      cardinality: relationship.cardinality,
      public?: relationship.public?
    }
  end

  # ---------------------------------------------------------------------------
  # The decoration
  # ---------------------------------------------------------------------------

  describe "the decorated record" do
    test "every relationship on every fixture resource is stored" do
      for module <- resources(),
          relationship <- Ash.Resource.Info.relationships(module) do
        assert Custom.relationship(decoration(module), relationship.name, @default_namespace) ==
                 record(relationship),
               "#{inspect(module)}.#{relationship.name} is not decorated"
      end
    end

    test "a string name reads the same record as an atom" do
      decoration = decoration(Test.Address)

      assert Custom.relationship(decoration, "user", @default_namespace) ==
               Custom.relationship(decoration, :user, @default_namespace)
    end

    test "a name nobody declared is nil, not a missing decoration" do
      assert Custom.relationship(decoration(Test.User), :no_such_relationship) == nil
    end

    test "public_relationship/3 answers nil for a private relationship" do
      assert Custom.public_relationship(decoration(Test.Address), :user) == nil

      assert Custom.public_relationship(decoration(Test.User), :address) ==
               record(Ash.Resource.Info.relationship(Test.User, :address))
    end

    test "an undecorated resource reads nil, so the caller can tell it apart" do
      assert Custom.relationship(%Ash.Info.Manifest.Resource{module: Test.Address}, :user) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # The private relationship the manifest omits
  # ---------------------------------------------------------------------------

  describe "the fixture the private case rests on" do
    test "Test.Address.user is private and absent from the fixture manifest" do
      refute Ash.Resource.Info.relationship(Test.Address, :user).public?

      assert Ash.Info.Manifest.Resource.get_relationship(decoration(Test.Address), :user) == nil,
             "the fixture manifest carries the private relationship, so decorating it proves nothing"
    end
  end
end
