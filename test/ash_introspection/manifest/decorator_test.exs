# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Manifest.DecoratorTest do
  @moduledoc """
  What `AshIntrospection.Manifest.Decorator` writes, and where.

  The differential test in `differential_test.exs` proves the decorated values
  match live introspection. This file proves the decoration reaches the right
  structs — resources, the resources nested inside embedded-resource types,
  named types, entrypoints and the manifest itself — and that the namespace is
  a real parameter rather than a constant with a default.
  """

  use ExUnit.Case, async: true

  alias Ash.Info.Manifest
  alias AshIntrospection.Manifest.Custom
  alias AshIntrospection.Manifest.Decorator
  alias AshIntrospection.Test
  alias AshIntrospection.Test.ManifestFixture

  describe "what gets decorated" do
    setup do
      %{manifest: ManifestFixture.decorated()}
    end

    test "every resource in the manifest", %{manifest: manifest} do
      assert manifest.resources != []

      for resource <- manifest.resources do
        assert Custom.decorated?(resource),
               "#{inspect(resource.module)} was left undecorated"
      end
    end

    test "every relationship on every resource", %{manifest: manifest} do
      for resource <- manifest.resources, {name, relationship} <- resource.relationships do
        assert Custom.decorated?(relationship),
               "#{inspect(resource.module)}.#{name} was left undecorated"
      end
    end

    test "the resource nested inside each embedded-resource type", %{manifest: manifest} do
      embedded = Enum.filter(manifest.types, &(&1.kind == :embedded_resource))
      assert embedded != [], "the fixture manifest carries no embedded resources"

      for type <- embedded do
        assert Custom.decorated?(type.resource),
               "the resource inside #{inspect(type.module)} was left undecorated"
      end
    end

    test "every entrypoint carries the client-facing name the callback gave it",
         %{manifest: manifest} do
      assert manifest.entrypoints != []

      for entrypoint <- manifest.entrypoints do
        name = Custom.entrypoint_client_name(entrypoint)

        assert name ==
                 ManifestFixture.entrypoint_name(entrypoint.resource, entrypoint.action.name)
      end
    end

    test "a type that pins its own field names", %{manifest: manifest} do
      decorated =
        Enum.filter(manifest.types, &(&1.kind != :embedded_resource and Custom.decorated?(&1)))

      assert decorated != [],
             "no named type in the fixture exports interop_field_names/0 — this test is vacuous"

      for type <- decorated do
        module = Manifest.Type.effective_module(type)
        mappings = Custom.field_name_mappings(type)

        assert mappings == Map.new(module.interop_field_names()),
               "field names diverged for #{inspect(module)}"

        assert Custom.original_field_name(type, Map.fetch!(mappings, hd(Map.keys(mappings)))) ==
                 hd(Map.keys(mappings))
      end
    end

    test "a type with no field-names callback is left alone", %{manifest: manifest} do
      plain =
        Enum.find(manifest.types, fn type ->
          type.kind != :embedded_resource and
            not function_exported?(Manifest.Type.effective_module(type), :interop_field_names, 0)
        end)

      if plain do
        refute Custom.decorated?(plain)
        assert Custom.field_name_mappings(plain) == %{}
      end
    end
  end

  describe "the entrypoint lookup" do
    test "is keyed by the client-facing name and holds every named entrypoint" do
      manifest = ManifestFixture.decorated()
      lookup = Custom.entrypoint_lookup(manifest)

      assert map_size(lookup) > 0

      for entrypoint <- manifest.entrypoints do
        name = Custom.entrypoint_client_name(entrypoint)
        assert Custom.entrypoint(manifest, name) == entrypoint
        assert Map.fetch!(lookup, name) == entrypoint
      end
    end

    test "finds the same entrypoint a scan would" do
      manifest = ManifestFixture.decorated()

      for entrypoint <- manifest.entrypoints do
        name = Custom.entrypoint_client_name(entrypoint)
        scanned = Enum.find(manifest.entrypoints, &(Custom.entrypoint_client_name(&1) == name))

        assert Custom.entrypoint(manifest, name) == scanned
      end
    end

    test "a name nobody exposed is not in it" do
      assert Custom.entrypoint(ManifestFixture.decorated(), "noSuchAction") == nil
    end

    test "with no :entrypoint_name callback, no entrypoint has a client name" do
      manifest = Decorator.decorate(ManifestFixture.manifest(), :ash_introspection, %{})

      assert Custom.entrypoint_lookup(manifest) == %{}
      assert Enum.all?(manifest.entrypoints, &(Custom.entrypoint_client_name(&1) == nil))
    end

    test "two entrypoints claiming one name fail the decoration, loudly" do
      config = %{entrypoint_name: fn _resource, _action -> "everything" end}

      assert_raise ArgumentError, ~r/Two entrypoints claim the client-facing name/, fn ->
        Decorator.decorate(ManifestFixture.manifest(), :ash_introspection, config)
      end
    end

    test "the client name comes from the :entrypoint_name callback when one is given" do
      config = %{entrypoint_name: fn resource, action -> "#{inspect(resource)}.#{action}" end}
      manifest = Decorator.decorate(ManifestFixture.manifest(), :ash_introspection, config)

      assert %Manifest.Entrypoint{} =
               entrypoint = Custom.entrypoint(manifest, "AshIntrospection.Test.User.read")

      assert entrypoint.resource == Test.User
      assert entrypoint.action.name == :read
    end

    test "an entrypoint the callback declines to name is left out of the lookup" do
      config = %{
        entrypoint_name: fn resource, action ->
          if resource == Test.User, do: ManifestFixture.entrypoint_name(resource, action)
        end
      }

      manifest = Decorator.decorate(ManifestFixture.manifest(), :ash_introspection, config)

      assert manifest |> Custom.entrypoint_lookup() |> Map.keys() |> Enum.sort() ==
               ["userCreate", "userRead", "userUpdate"]

      assert Custom.entrypoint(manifest, "accountRead") == nil
    end
  end

  describe "the namespace is a parameter" do
    test "decoration lands under the namespace it was given, and nowhere else" do
      manifest = Decorator.decorate(ManifestFixture.manifest(), :some_other_client)
      resource = Enum.find(manifest.resources, &(&1.module == Test.User))

      assert Custom.decorated?(resource, :some_other_client)
      refute Custom.decorated?(resource, :ash_introspection)
      assert Custom.attributes(resource, :ash_introspection) == []
    end

    test "two namespaces coexist on one manifest" do
      manifest =
        ManifestFixture.manifest()
        |> Decorator.decorate(:client_a)
        |> Decorator.decorate(:client_b)

      resource = Enum.find(manifest.resources, &(&1.module == Test.User))

      assert Custom.decorated?(resource, :client_a)
      assert Custom.decorated?(resource, :client_b)
      assert Custom.attributes(resource, :client_a) == Custom.attributes(resource, :client_b)
    end
  end

  describe "the callbacks the consumer supplies" do
    test ":format_field_for_client decides the client-facing names" do
      config = %{
        format_field_for_client: fn field, _resource, formatter -> "#{formatter}:#{field}" end
      }

      manifest = Decorator.decorate(ManifestFixture.manifest(), :ash_introspection, config)
      resource = Enum.find(manifest.resources, &(&1.module == Test.User))

      assert Custom.formatted_field_name(resource, :id, :camel_case) == "camel_case:id"
      assert Custom.formatted_field_name(resource, :id, :snake_case) == "snake_case:id"
      assert Custom.original_field_name(resource, "camel_case:id") == :id
    end

    test ":format_field_for_client names action arguments too" do
      config = %{
        format_field_for_client: fn field, _resource, formatter -> "#{formatter}:#{field}" end
      }

      manifest = Decorator.decorate(ManifestFixture.manifest(), :ash_introspection, config)
      resource = Enum.find(manifest.resources, &(&1.module == Test.Document))

      assert Custom.formatted_argument_name(resource, :attach, :attachment, :camel_case) ==
               "camel_case:attachment"

      assert Custom.original_argument_name(resource, :attach, "camel_case:attachment") ==
               :attachment
    end

    test ":get_original_field_name does not touch argument names" do
      # The callback answers "which field is this client name?", and an
      # argument is not a field. Overriding the argument inverse with a field
      # answer would rename an argument nobody asked to rename.
      config = %{
        get_original_field_name: fn _resource, _client_name -> :something_else end
      }

      manifest = Decorator.decorate(ManifestFixture.manifest(), :ash_introspection, config)
      resource = Enum.find(manifest.resources, &(&1.module == Test.Document))

      assert Custom.original_argument_name(resource, :attach, "attachment") == :attachment
      assert Custom.original_field_name(resource, "id") == :something_else
    end

    test ":get_original_field_name overrides the computed inverse" do
      config = %{
        get_original_field_name: fn
          _resource, "id" -> :something_else
          _resource, _other -> nil
        end
      }

      manifest = Decorator.decorate(ManifestFixture.manifest(), :ash_introspection, config)
      resource = Enum.find(manifest.resources, &(&1.module == Test.User))

      assert Custom.original_field_name(resource, "id") == :something_else
    end

    test "with no callbacks, names come from FieldFormatter" do
      resource = Enum.find(ManifestFixture.decorated().resources, &(&1.module == Test.User))

      for field <- [:id, :email], formatter <- [:camel_case, :pascal_case, :snake_case] do
        assert Custom.formatted_field_name(resource, field, formatter) ==
                 AshIntrospection.FieldFormatter.format_field_name(field, formatter)
      end
    end

    test "a formatter nobody precomputed answers nil rather than guessing" do
      resource = Enum.find(ManifestFixture.decorated().resources, &(&1.module == Test.User))

      assert Custom.formatted_field_name(resource, :id, :screaming_case) == nil
    end
  end

  describe "decorate/3 is pure" do
    test "the same manifest and config give the same result" do
      manifest = ManifestFixture.manifest()

      assert Decorator.decorate(manifest, :ash_introspection) ==
               Decorator.decorate(manifest, :ash_introspection)
    end

    test "decorating twice with the same config is the same as decorating once" do
      once = ManifestFixture.decorated()

      assert Decorator.decorate(once, :ash_introspection, ManifestFixture.decorator_config()) ==
               once
    end

    test "the undecorated manifest is untouched" do
      before = ManifestFixture.manifest()
      _ = Decorator.decorate(before, :ash_introspection)

      assert ManifestFixture.manifest() == before
      assert Custom.entrypoint_lookup(before) == %{}
    end
  end

  describe "an undecorated struct answers empty, never wrong" do
    test "every reader has a defined answer for nil and for a bare struct" do
      bare = %Manifest.Resource{module: Test.User}

      for struct <- [nil, bare] do
        refute Custom.decorated?(struct)
        assert Custom.attributes(struct) == []
        assert Custom.public_attributes(struct) == []
        assert Custom.public_calculations(struct) == []
        assert Custom.public_aggregates(struct) == []
        assert Custom.actions(struct) == []
        assert Custom.attribute(struct, :id) == nil
        assert Custom.public_attribute(struct, :id) == nil
        assert Custom.calculation(struct, :id) == nil
        assert Custom.public_calculation(struct, :id) == nil
        assert Custom.aggregate(struct, :id) == nil
        assert Custom.public_aggregate(struct, :id) == nil
        assert Custom.action(struct, :read) == nil
        assert Custom.aggregate_type(struct, :id) == :undecorated
        assert Custom.return_classification(struct, :read) == :undecorated
        assert Custom.authorize_bulk_strategy(struct) == nil
        assert Custom.field_name_mappings(struct) == %{}
        assert Custom.reverse_field_name_mappings(struct) == %{}
        assert Custom.mapped_field_name(struct, :id) == nil
        assert Custom.original_field_name(struct, "id") == nil
        assert Custom.formatted_field_name(struct, :id, :camel_case) == nil
        assert Custom.relationship_pagination(struct) == :none
        assert Custom.relationship_read_action(struct) == nil
        assert Custom.argument_name_mappings(struct, :read) == %{}
        assert Custom.reverse_argument_name_mappings(struct, :read) == %{}
        assert Custom.mapped_argument_name(struct, :read, :id) == nil
        assert Custom.original_argument_name(struct, :read, "id") == nil
        assert Custom.formatted_argument_name(struct, :read, :id, :camel_case) == nil
      end
    end

    test "an undecorated aggregate says :undecorated, which is not nil" do
      # `nil` is a legitimate resolved aggregate type, so it cannot double as
      # the "read this live instead" signal.
      resource = Enum.find(ManifestFixture.decorated().resources, &(&1.module == Test.User))

      assert Custom.aggregate_type(resource, :no_such_aggregate) == :undecorated
    end
  end
end
