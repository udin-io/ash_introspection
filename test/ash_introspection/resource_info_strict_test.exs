# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.ResourceInfoStrictTest do
  @moduledoc """
  What `AshIntrospection.ResourceInfo.require_manifest!/1` changes, and what it
  deliberately leaves alone.

  A strict source is the mechanism behind #23 stage 5a PR 6. The four request
  entry points arm it; nothing else does, because the compile-time verifiers,
  `AshIntrospection.Codegen` and `AshIntrospection.Manifest.Decorator` call the
  same readers before a decorated manifest exists and have to keep reading
  live.

  Three claims:

  1. `require_manifest!/1` raises when the config carries no manifest, and
     arms `strict?: true` when it carries one.
  2. Under a strict source, a resource the manifest carries but the decorator
     did not decorate raises instead of reading live.
  3. Under a strict source, `primary_key/2` and `identity_keys/3` raise for a
     resource the manifest does not carry. The field and relationship readers
     do not — `runtime_resource?/2` keeps its live fallback so a module nobody
     declared still serializes as a resource, and those readers are what
     serializing it calls.
  """

  use ExUnit.Case, async: true

  alias AshIntrospection.ManifestError
  alias AshIntrospection.ResourceInfo
  alias AshIntrospection.ResourceInfo.Source
  alias AshIntrospection.Test
  alias AshIntrospection.Test.ManifestFixture

  # `Test.EmbeddedAddress` is reachable from no fixture entrypoint, so the
  # manifest does not carry it while `Ash.Resource.Info.resource?/1` answers
  # `true`. See `ManifestFixture`'s moduledoc.
  @uncarried Test.EmbeddedAddress

  defp strict, do: ResourceInfo.require_manifest!(ManifestFixture.decorated_config())

  defp strict_undecorated, do: ResourceInfo.require_manifest!(ManifestFixture.config())

  describe "require_manifest!/1" do
    test "raises when the config carries no manifest" do
      assert_raise ManifestError, ~r/requires a manifest/, fn ->
        ResourceInfo.require_manifest!(%{})
      end
    end

    test "raises when the config carries an explicit nil manifest" do
      assert_raise ManifestError, ~r/requires a manifest/, fn ->
        ResourceInfo.require_manifest!(%{manifest: nil})
      end
    end

    test "arms strict? on the prepared source" do
      assert %{manifest: %Source{strict?: true}} = strict()
    end

    test "prepares a bare manifest and keeps the namespace" do
      config = %{
        manifest: ManifestFixture.decorated(:brief_test),
        manifest_namespace: :brief_test
      }

      assert %{manifest: %Source{strict?: true, namespace: :brief_test}} =
               ResourceInfo.require_manifest!(config)
    end

    test "is idempotent" do
      once = strict()

      assert ResourceInfo.require_manifest!(once) == once
    end
  end

  describe "a missed decoration raises" do
    setup do
      %{config: strict_undecorated()}
    end

    test "attribute/3", %{config: config} do
      assert_raise ManifestError, ~r/did not decorate/, fn ->
        ResourceInfo.attribute(Test.User, :name, config)
      end
    end

    test "action/3", %{config: config} do
      assert_raise ManifestError, ~r/did not decorate/, fn ->
        ResourceInfo.action(Test.User, :read, config)
      end
    end

    test "relationship/3", %{config: config} do
      assert_raise ManifestError, ~r/did not decorate/, fn ->
        ResourceInfo.relationship(Test.User, :address, config)
      end
    end

    test "public_relationship/3", %{config: config} do
      assert_raise ManifestError, ~r/did not decorate/, fn ->
        ResourceInfo.public_relationship(Test.User, :address, config)
      end
    end

    test "authorize_bulk_strategy/2", %{config: config} do
      assert_raise ManifestError, ~r/did not decorate/, fn ->
        ResourceInfo.authorize_bulk_strategy(Test.User, config)
      end
    end

    test "the message names the resource and the namespace", %{config: config} do
      error =
        assert_raise ManifestError, fn ->
          ResourceInfo.attribute(Test.User, :name, config)
        end

      assert error.reason == :undecorated
      assert error.resource == Test.User
      assert error.namespace == :ash_introspection
      assert error.message =~ "AshIntrospection.Test.User"
      assert error.message =~ "custom.ash_introspection"
    end

    test "an embedded resource the manifest carries as a type raises too", %{config: config} do
      embedded = hd(ManifestFixture.embedded_modules())

      assert_raise ManifestError, ~r/did not decorate/, fn ->
        ResourceInfo.attributes(embedded, config)
      end
    end

    test "a decorated resource answers" do
      assert %{name: :name} = ResourceInfo.attribute(Test.User, :name, strict())
      assert %{cardinality: :one} = ResourceInfo.relationship(Test.User, :address, strict())
    end
  end

  describe "the manifest-miss live reads are gone for the request's own resource" do
    setup do
      %{config: strict()}
    end

    test "primary_key/2 raises for a resource the manifest does not carry", %{config: config} do
      assert_raise ManifestError, ~r/does not carry/, fn ->
        ResourceInfo.primary_key(@uncarried, config)
      end
    end

    test "identity_keys/3 raises for a resource the manifest does not carry", %{config: config} do
      assert_raise ManifestError, ~r/does not carry/, fn ->
        ResourceInfo.identity_keys(@uncarried, :whatever, config)
      end
    end

    test "the message names the reader", %{config: config} do
      error =
        assert_raise ManifestError, fn -> ResourceInfo.primary_key(@uncarried, config) end

      assert error.reason == :unknown_resource
      assert error.resource == @uncarried
      assert error.message =~ "primary_key/2"
    end

    test "both answer for a resource the manifest carries", %{config: config} do
      assert ResourceInfo.primary_key(Test.Account, config) == [:id]
      assert ResourceInfo.identity_keys(Test.Account, :unique_email, config) == [:email]
    end
  end

  describe "a module the manifest does not carry still serializes as a resource" do
    setup do
      %{config: strict()}
    end

    test "runtime_resource?/2 keeps its live fallback", %{config: config} do
      assert ResourceInfo.runtime_resource?(@uncarried, config)
      refute ResourceInfo.declared_resource?(@uncarried, config)
    end

    test "embedded?/2 keeps its live fallback", %{config: config} do
      assert ResourceInfo.embedded?(@uncarried, config)
    end

    test "the field readers keep theirs", %{config: config} do
      # `ValueFormatter.format_resource/4` types every key of such a resource
      # through these. Raising here would contradict `runtime_resource?/2`.
      assert %{name: :street} = ResourceInfo.attribute(@uncarried, :street, config)
      assert ResourceInfo.attributes(@uncarried, config) != []
      assert ResourceInfo.public_attributes(@uncarried, config) != []
      assert ResourceInfo.relationship(@uncarried, :nope, config) == nil
      assert ResourceInfo.public_relationship(@uncarried, :nope, config) == nil
    end

    test "public_field_names/2 keeps its live fallback", %{config: config} do
      assert :street in ResourceInfo.public_field_names(@uncarried, config)
    end
  end

  describe "nothing changes without require_manifest!/1" do
    test "an undecorated manifest still reads live" do
      config = ManifestFixture.config()

      assert %{name: :name} = ResourceInfo.attribute(Test.User, :name, config)
      assert %{cardinality: :one} = ResourceInfo.relationship(Test.User, :address, config)

      assert ResourceInfo.primary_key(@uncarried, config) ==
               Ash.Resource.Info.primary_key(@uncarried)

      assert ResourceInfo.identity_keys(@uncarried, :nope, config) == nil
    end

    test "a decorated manifest that was not armed still reads live on a miss" do
      config = ManifestFixture.decorated_config()

      assert ResourceInfo.primary_key(@uncarried, config) ==
               Ash.Resource.Info.primary_key(@uncarried)

      assert %{name: :street} = ResourceInfo.attribute(@uncarried, :street, config)
    end

    test "prepare/2 leaves strict? false" do
      assert %Source{strict?: false} = ResourceInfo.prepare(ManifestFixture.decorated())
    end
  end
end
