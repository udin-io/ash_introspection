# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.ResourceInfoTest do
  @moduledoc """
  The two guarantees `AshIntrospection.ResourceInfo` makes, and the one place
  the two sources are allowed to disagree.

  1. **Omitting `:manifest` changes nothing.** Every read without the key is
     compared against `Ash.Resource.Info` itself, so a delegation that drifts
     fails here rather than in a consumer.
  2. **With `:manifest`, the manifest-backed readers give the same answer.**
     This is the differential test `docs/risks.md` T2 records as missing — the
     first place the two sources are run against each other field by field.
  3. **`resource?/1` and `has_resource?/2` are different questions**, and the
     module answers both on purpose.
  """

  use ExUnit.Case, async: true

  alias AshIntrospection.ResourceInfo
  alias AshIntrospection.Test
  alias AshIntrospection.Test.ManifestFixture

  @live %{}

  # Resources the fixture manifest carries, plus their fields, read off the
  # manifest so a fixture change cannot leave this list stale.
  defp manifest_resources, do: ManifestFixture.resource_modules()

  defp every_field(resource) do
    Enum.map(Ash.Resource.Info.public_attributes(resource), & &1.name) ++
      Enum.map(Ash.Resource.Info.public_calculations(resource), & &1.name) ++
      Enum.map(Ash.Resource.Info.public_aggregates(resource), & &1.name) ++
      Enum.map(Ash.Resource.Info.public_relationships(resource), & &1.name)
  end

  describe "no :manifest key — the compatibility guarantee" do
    test "classification matches Ash.Resource.Info for resources, embedded resources and non-resources" do
      resources =
        manifest_resources() ++ ManifestFixture.embedded_modules() ++ [Test.EmbeddedAddress]

      non_resources = [Test.CustomType, Enum, String, NotAModuleAtAll]

      for module <- resources ++ non_resources do
        assert ResourceInfo.runtime_resource?(module, @live) ==
                 Ash.Resource.Info.resource?(module),
               "runtime_resource?/2 diverged for #{inspect(module)}"

        assert ResourceInfo.declared_resource?(module, @live) ==
                 Ash.Resource.Info.resource?(module),
               "declared_resource?/2 diverged for #{inspect(module)}"
      end

      for module <- resources do
        assert ResourceInfo.embedded?(module, @live) == Ash.Resource.Info.embedded?(module),
               "embedded?/2 diverged for #{inspect(module)}"
      end
    end

    test "embedded?/2 raises for a non-resource, exactly as Ash.Resource.Info does" do
      # `Ash.Resource.Info.embedded?/1` reads persisted Spark DSL state and
      # raises `ArgumentError` for any module that is not a Spark DSL module —
      # it is not a safe classifier for an arbitrary atom. Preserving the raise
      # is part of the compatibility guarantee; swallowing it would make a
      # non-resource look like a non-embedded resource.
      for module <- [Test.CustomType, Enum, NotAModuleAtAll] do
        assert_raise ArgumentError, fn -> Ash.Resource.Info.embedded?(module) end
        assert_raise ArgumentError, fn -> ResourceInfo.embedded?(module, @live) end

        assert_raise ArgumentError, fn ->
          ResourceInfo.embedded?(module, ManifestFixture.config())
        end
      end
    end

    test "shape readers match Ash.Resource.Info across every fixture resource and field" do
      for resource <- manifest_resources() do
        assert ResourceInfo.primary_key(resource, @live) ==
                 Ash.Resource.Info.primary_key(resource)

        assert Enum.sort(ResourceInfo.public_field_names(resource, @live)) ==
                 Enum.sort(
                   Enum.map(Ash.Resource.Info.public_attributes(resource), & &1.name) ++
                     Enum.map(Ash.Resource.Info.public_calculations(resource), & &1.name) ++
                     Enum.map(Ash.Resource.Info.public_aggregates(resource), & &1.name)
                 )

        for identity <- Ash.Resource.Info.identities(resource) do
          assert ResourceInfo.identity_keys(resource, identity.name, @live) == identity.keys
        end

        assert ResourceInfo.identity_keys(resource, :no_such_identity, @live) == nil

        for name <- every_field(resource) do
          live_relationship = Ash.Resource.Info.relationship(resource, name)

          assert ResourceInfo.relationship(resource, name, @live) ==
                   narrow(live_relationship),
                 "relationship/3 diverged for #{inspect(resource)}.#{name}"

          assert ResourceInfo.public_relationship(resource, name, @live) ==
                   narrow(Ash.Resource.Info.public_relationship(resource, name))

          assert ResourceInfo.attribute(resource, name, @live) ==
                   Ash.Resource.Info.attribute(resource, name)

          assert ResourceInfo.public_attribute(resource, name, @live) ==
                   Ash.Resource.Info.public_attribute(resource, name)

          assert ResourceInfo.calculation(resource, name, @live) ==
                   Ash.Resource.Info.calculation(resource, name)

          assert ResourceInfo.public_calculation(resource, name, @live) ==
                   Ash.Resource.Info.public_calculation(resource, name)

          assert ResourceInfo.aggregate(resource, name, @live) ==
                   Ash.Resource.Info.aggregate(resource, name)

          assert ResourceInfo.public_aggregate(resource, name, @live) ==
                   Ash.Resource.Info.public_aggregate(resource, name)
        end

        assert ResourceInfo.attributes(resource, @live) == Ash.Resource.Info.attributes(resource)

        assert ResourceInfo.public_attributes(resource, @live) ==
                 Ash.Resource.Info.public_attributes(resource)

        assert ResourceInfo.public_calculations(resource, @live) ==
                 Ash.Resource.Info.public_calculations(resource)

        assert ResourceInfo.public_aggregates(resource, @live) ==
                 Ash.Resource.Info.public_aggregates(resource)

        assert ResourceInfo.actions(resource, @live) == Ash.Resource.Info.actions(resource)

        for action <- Ash.Resource.Info.actions(resource) do
          assert ResourceInfo.action(resource, action.name, @live) ==
                   Ash.Resource.Info.action(resource, action.name)
        end

        for aggregate <- Ash.Resource.Info.public_aggregates(resource) do
          assert ResourceInfo.aggregate_type(resource, aggregate, @live) ==
                   Ash.Resource.Info.aggregate_type(resource, aggregate)
        end
      end
    end

    test "the config argument is optional and defaults to live" do
      assert ResourceInfo.runtime_resource?(Test.User) == true
      assert ResourceInfo.declared_resource?(Test.EmbeddedAddress) == true
      assert ResourceInfo.primary_key(Test.User) == [:id]
      assert ResourceInfo.action(Test.User, :read).name == :read
    end

    test "a nil :manifest value reads live" do
      config = %{manifest: nil}

      assert ResourceInfo.source(config) == nil
      assert ResourceInfo.declared_resource?(Test.EmbeddedAddress, config) == true
    end
  end

  describe "with :manifest — the differential test" do
    test "the manifest-backed readers agree with live introspection, field for field" do
      manifest_config = ManifestFixture.config()

      for resource <- manifest_resources() do
        assert ResourceInfo.runtime_resource?(resource, manifest_config) ==
                 ResourceInfo.runtime_resource?(resource, @live)

        assert ResourceInfo.declared_resource?(resource, manifest_config) ==
                 ResourceInfo.declared_resource?(resource, @live)

        assert ResourceInfo.embedded?(resource, manifest_config) ==
                 ResourceInfo.embedded?(resource, @live)

        assert ResourceInfo.primary_key(resource, manifest_config) ==
                 ResourceInfo.primary_key(resource, @live)

        assert Enum.sort(ResourceInfo.public_field_names(resource, manifest_config)) ==
                 Enum.sort(ResourceInfo.public_field_names(resource, @live))

        for identity <- Ash.Resource.Info.identities(resource) do
          assert ResourceInfo.identity_keys(resource, identity.name, manifest_config) ==
                   ResourceInfo.identity_keys(resource, identity.name, @live)
        end

        for name <- every_field(resource) do
          assert ResourceInfo.relationship(resource, name, manifest_config) ==
                   ResourceInfo.relationship(resource, name, @live),
                 "relationship/3 disagreed for #{inspect(resource)}.#{name}"

          assert ResourceInfo.public_relationship(resource, name, manifest_config) ==
                   ResourceInfo.public_relationship(resource, name, @live)
        end
      end
    end

    test "embedded resources carried as manifest types answer like resources" do
      manifest_config = ManifestFixture.config()

      embedded = ManifestFixture.embedded_modules()
      assert embedded != [], "the fixture manifest carries no embedded resources"

      for module <- embedded do
        assert ResourceInfo.declared_resource?(module, manifest_config)
        assert ResourceInfo.runtime_resource?(module, manifest_config)
        assert ResourceInfo.embedded?(module, manifest_config)

        assert Enum.sort(ResourceInfo.public_field_names(module, manifest_config)) ==
                 Enum.sort(ResourceInfo.public_field_names(module, @live))
      end
    end

    test "the fixture manifest really is read, not quietly ignored" do
      # Without this, every assertion above would also pass against a reader
      # that never looked at the manifest. A module absent from the manifest is
      # the one input whose answer must differ.
      refute ResourceInfo.declared_resource?(Test.EmbeddedAddress, ManifestFixture.config())
      assert ResourceInfo.declared_resource?(Test.EmbeddedAddress, @live)
    end

    test "a bare %Ash.Info.Manifest{} works as well as a prepared source" do
      bare = %{manifest: ManifestFixture.manifest()}
      prepared = ManifestFixture.config()

      assert ResourceInfo.primary_key(Test.User, bare) ==
               ResourceInfo.primary_key(Test.User, prepared)

      refute ResourceInfo.declared_resource?(Test.EmbeddedAddress, bare)
    end

    test "normalize_config/1 prepares the manifest once and leaves other configs alone" do
      normalized = ResourceInfo.normalize_config(%{manifest: ManifestFixture.manifest()})
      assert %ResourceInfo.Source{} = normalized.manifest

      assert ResourceInfo.normalize_config(%{other: :key}) == %{other: :key}
      assert ResourceInfo.normalize_config(%{}) == %{}
    end
  end

  describe "resource?/1 is not has_resource?/2" do
    setup do
      %{config: ManifestFixture.config(), source: ManifestFixture.source()}
    end

    test "a module absent from the manifest: live says resource, the manifest says nothing",
         %{config: config, source: source} do
      absent = Test.EmbeddedAddress

      assert Ash.Resource.Info.resource?(absent),
             "fixture assumption broken: #{inspect(absent)} is not an Ash resource"

      refute Ash.Info.Manifest.has_resource?(source.resources, absent),
             "fixture assumption broken: #{inspect(absent)} reached the manifest"

      # The request path must keep serializing it as a resource.
      assert ResourceInfo.runtime_resource?(absent, config)

      # Codegen must not emit a type for something nobody exposed.
      refute ResourceInfo.declared_resource?(absent, config)
    end

    test "an embedded resource is a manifest type, so has_resource?/2 alone would miss it",
         %{config: config, source: source} do
      [embedded | _] = ManifestFixture.embedded_modules()

      refute Ash.Info.Manifest.has_resource?(source.resources, embedded),
             "#{inspect(embedded)} is in manifest.resources — the trap this test names is gone"

      assert Ash.Resource.Info.resource?(embedded)
      assert Ash.Resource.Info.embedded?(embedded)

      # Both readers count it, so neither diverges from live for a *declared*
      # embedded resource. Absence is the only divergence.
      assert ResourceInfo.runtime_resource?(embedded, config)
      assert ResourceInfo.declared_resource?(embedded, config)
      assert ResourceInfo.embedded?(embedded, config)
    end

    test "the two agree on everything the manifest does carry", %{config: config} do
      for module <- manifest_resources() ++ ManifestFixture.embedded_modules() do
        assert ResourceInfo.runtime_resource?(module, config) ==
                 ResourceInfo.declared_resource?(module, config)
      end
    end

    test "neither reader accepts a non-module", %{config: config} do
      for value <- [nil, "Test.User", 42, %{}, {:array, Test.User}] do
        refute ResourceInfo.runtime_resource?(value, config)
        refute ResourceInfo.declared_resource?(value, config)
        refute ResourceInfo.embedded?(value, config)
      end
    end
  end

  defp narrow(nil), do: nil

  defp narrow(relationship) do
    %{
      name: relationship.name,
      destination: relationship.destination,
      cardinality: relationship.cardinality
    }
  end
end
