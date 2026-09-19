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
  alias AshIntrospection.Test.ManifestTamper

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

  # ---------------------------------------------------------------------------
  # The reader
  # ---------------------------------------------------------------------------

  describe "relationship/3 reads the decoration" do
    test "a tampered destination beats the manifest's own relationship" do
      tampered = tamper(&ManifestTamper.retarget(&1, &2, Test.User, :address, Test.Account))

      assert ResourceInfo.relationship(Test.User, :address, tampered).destination == Test.Account

      assert ResourceInfo.relationship(Test.User, :address, decorated_config()).destination ==
               Test.Address
    end

    test "a tampered destination beats live introspection for a private relationship" do
      tampered = tamper(&ManifestTamper.retarget(&1, &2, Test.Address, :user, Test.Account))

      assert ResourceInfo.relationship(Test.Address, :user, tampered).destination == Test.Account

      assert ResourceInfo.relationship(Test.Address, :user, decorated_config()).destination ==
               Test.User
    end

    test "the narrow map drops public?, so the return shape is unchanged" do
      assert ResourceInfo.relationship(Test.Address, :user, decorated_config()) == %{
               name: :user,
               destination: Test.User,
               cardinality: :one
             }
    end
  end

  describe "public_relationship/3 reads the decoration" do
    test "a relationship the decoration marks private is refused" do
      tampered = tamper(&ManifestTamper.hide_relationship(&1, &2, Test.User, :address))

      assert ResourceInfo.public_relationship(Test.User, :address, tampered) == nil

      # The private reader still answers, so the tamper changed visibility and
      # not the record's presence.
      assert ResourceInfo.relationship(Test.User, :address, tampered).destination == Test.Address

      assert ResourceInfo.public_relationship(Test.User, :address, decorated_config()) == %{
               name: :address,
               destination: Test.Address,
               cardinality: :one
             }
    end

    test "a manifest built with private relationships still refuses one" do
      # This is the answer the manifest alone gets wrong.
      # `%Ash.Info.Manifest.Relationship{}` carries no `public?`, so reading the
      # manifest's own relationship map hands a private `belongs_to` back as
      # public whenever the manifest was built with
      # `include_private_relationships?: true` — which is what the consumer
      # does (`ash_kotlin_multiplatform` `build_manifest.ex:69`).
      config = %{manifest: ResourceInfo.prepare(with_private_relationships())}

      assert Ash.Info.Manifest.Resource.get_relationship(
               ResourceInfo.decoration(Test.Address, config) |> elem(0),
               :user
             ),
             "the manifest was not built with private relationships, so this proves nothing"

      assert ResourceInfo.public_relationship(Test.Address, :user, config) == nil

      assert ResourceInfo.relationship(Test.Address, :user, config) == %{
               name: :user,
               destination: Test.User,
               cardinality: :one
             }
    end
  end

  defp tamper(fun) do
    %{manifest: ResourceInfo.prepare(fun.(ManifestFixture.decorated(), @default_namespace))}
  end

  defp with_private_relationships do
    {:ok, manifest} =
      Ash.Info.Manifest.generate(
        otp_app: :ash_introspection,
        action_entrypoints: ManifestFixture.entrypoints(),
        include_private_relationships?: true
      )

    AshIntrospection.Manifest.Decorator.decorate(
      manifest,
      @default_namespace,
      ManifestFixture.decorator_config()
    )
  end
end
