# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Manifest.DifferentialTest do
  @moduledoc """
  Runs both sources over every fixture resource and asserts they agree.

  Issue #23 replaces live `Ash.Resource.Info` introspection with a precomputed
  manifest, in five stages, with both paths live at once for two releases. Two
  paths that can disagree are only safe if something says when they do. This is
  that something: for every resource, every field and every action in
  `test/support/`, the answer read through a decorated manifest must equal the
  answer read live.

  `docs/risks.md` T2 records the absence of a contract test between this
  library and its consumer. This does not close T2 — it covers the reader's
  surface, not the consumer's call sites — but it is the half of T2 that lives
  in this repo, and the half that stages 3 to 5 lean on.

  ## Why this test can fail

  It would be a worthless test if it could not. Three ways it does:

    * the decorator captures the wrong struct, or captures it for the wrong
      resource — the field-for-field comparison catches it;
    * a reader routes to the manifest where the manifest cannot answer — the
      answer changes shape and the comparison catches it;
    * the decorator is skipped and nothing notices. `decoration_is_read/0`
      below is the guard: it asserts the decorated path is reached at all, so
      the rest of the file cannot pass vacuously against a reader that ignores
      its manifest.
  """

  use ExUnit.Case, async: true

  alias AshIntrospection.Manifest.Custom
  alias AshIntrospection.ResourceInfo
  alias AshIntrospection.Test.ManifestFixture
  alias AshIntrospection.TypeSystem.ResourceFields

  @live %{}

  setup_all do
    %{manifest: ManifestFixture.decorated_config()}
  end

  defp resources do
    ManifestFixture.resource_modules() ++ ManifestFixture.embedded_modules()
  end

  defp field_names(resource) do
    Enum.map(Ash.Resource.Info.attributes(resource), & &1.name) ++
      Enum.map(Ash.Resource.Info.calculations(resource), & &1.name) ++
      Enum.map(Ash.Resource.Info.aggregates(resource), & &1.name) ++
      Enum.map(Ash.Resource.Info.relationships(resource), & &1.name)
  end

  describe "the guard" do
    test "the decorated manifest really is read", %{manifest: manifest} do
      # Every assertion below would also pass against a reader that ignored the
      # manifest and answered live. This one would not: a resource the manifest
      # does not carry is the single input whose answer must differ.
      refute ResourceInfo.declared_resource?(AshIntrospection.Test.EmbeddedAddress, manifest)
      assert ResourceInfo.declared_resource?(AshIntrospection.Test.EmbeddedAddress, @live)
    end

    test "every fixture resource is decorated", %{manifest: manifest} do
      source = Map.fetch!(manifest, :manifest)

      for resource <- resources() do
        entry =
          Map.get(source.resources, resource) ||
            Map.get(source.types, resource).resource

        assert Custom.decorated?(entry, source.namespace),
               "#{inspect(resource)} reached this test undecorated, so its reads fell back to live"
      end
    end

    test "an undecorated manifest still answers, by falling back" do
      # The decorator skips a module it cannot load, so a manifest can carry a
      # resource with no decoration on it. Those reads must be identical too —
      # they are the live ones.
      undecorated = ManifestFixture.config()

      for resource <- resources() do
        assert ResourceInfo.attributes(resource, undecorated) ==
                 Ash.Resource.Info.attributes(resource)

        assert ResourceInfo.actions(resource, undecorated) ==
                 Ash.Resource.Info.actions(resource)
      end
    end
  end

  describe "field readers agree, field for field" do
    test "attributes", %{manifest: manifest} do
      for resource <- resources() do
        assert ResourceInfo.attributes(resource, manifest) ==
                 ResourceInfo.attributes(resource, @live)

        assert ResourceInfo.public_attributes(resource, manifest) ==
                 ResourceInfo.public_attributes(resource, @live)

        for name <- field_names(resource), spelling <- [name, to_string(name)] do
          assert ResourceInfo.attribute(resource, spelling, manifest) ==
                   ResourceInfo.attribute(resource, spelling, @live),
                 "attribute/3 disagreed for #{inspect(resource)}.#{name}"

          assert ResourceInfo.public_attribute(resource, spelling, manifest) ==
                   ResourceInfo.public_attribute(resource, spelling, @live),
                 "public_attribute/3 disagreed for #{inspect(resource)}.#{name}"
        end
      end
    end

    test "calculations", %{manifest: manifest} do
      for resource <- resources() do
        assert ResourceInfo.public_calculations(resource, manifest) ==
                 ResourceInfo.public_calculations(resource, @live)

        for name <- field_names(resource), spelling <- [name, to_string(name)] do
          assert ResourceInfo.calculation(resource, spelling, manifest) ==
                   ResourceInfo.calculation(resource, spelling, @live),
                 "calculation/3 disagreed for #{inspect(resource)}.#{name}"

          assert ResourceInfo.public_calculation(resource, spelling, manifest) ==
                   ResourceInfo.public_calculation(resource, spelling, @live),
                 "public_calculation/3 disagreed for #{inspect(resource)}.#{name}"
        end
      end
    end

    test "aggregates, and their resolved types", %{manifest: manifest} do
      for resource <- resources() do
        assert ResourceInfo.public_aggregates(resource, manifest) ==
                 ResourceInfo.public_aggregates(resource, @live)

        for name <- field_names(resource), spelling <- [name, to_string(name)] do
          assert ResourceInfo.aggregate(resource, spelling, manifest) ==
                   ResourceInfo.aggregate(resource, spelling, @live),
                 "aggregate/3 disagreed for #{inspect(resource)}.#{name}"

          assert ResourceInfo.public_aggregate(resource, spelling, manifest) ==
                   ResourceInfo.public_aggregate(resource, spelling, @live),
                 "public_aggregate/3 disagreed for #{inspect(resource)}.#{name}"
        end

        for aggregate <- Ash.Resource.Info.aggregates(resource) do
          assert ResourceInfo.aggregate_type(resource, aggregate, manifest) ==
                   ResourceInfo.aggregate_type(resource, aggregate, @live),
                 "aggregate_type/3 disagreed for #{inspect(resource)}.#{aggregate.name}"
        end
      end
    end

    test "a field nobody declared is missing from both", %{manifest: manifest} do
      for resource <- resources() do
        for reader <- [:attribute, :public_attribute, :calculation, :aggregate] do
          assert apply(ResourceInfo, reader, [resource, :no_such_field, manifest]) == nil
          assert apply(ResourceInfo, reader, [resource, "no_such_field", manifest]) == nil
        end
      end
    end
  end

  describe "action readers agree" do
    test "actions, one by one and as a list", %{manifest: manifest} do
      for resource <- resources() do
        assert ResourceInfo.actions(resource, manifest) ==
                 ResourceInfo.actions(resource, @live)

        for action <- Ash.Resource.Info.actions(resource) do
          assert ResourceInfo.action(resource, action.name, manifest) ==
                   ResourceInfo.action(resource, action.name, @live),
                 "action/3 disagreed for #{inspect(resource)}.#{action.name}"
        end

        assert ResourceInfo.action(resource, :no_such_action, manifest) == nil
      end
    end
  end

  describe "readers stage 1 already backed still agree" do
    test "classification, keys, relationships and field names", %{manifest: manifest} do
      for resource <- resources() do
        assert ResourceInfo.runtime_resource?(resource, manifest) ==
                 ResourceInfo.runtime_resource?(resource, @live)

        assert ResourceInfo.embedded?(resource, manifest) ==
                 ResourceInfo.embedded?(resource, @live)

        assert ResourceInfo.primary_key(resource, manifest) ==
                 ResourceInfo.primary_key(resource, @live)

        assert Enum.sort(ResourceInfo.public_field_names(resource, manifest)) ==
                 Enum.sort(ResourceInfo.public_field_names(resource, @live))

        for identity <- Ash.Resource.Info.identities(resource) do
          assert ResourceInfo.identity_keys(resource, identity.name, manifest) ==
                   ResourceInfo.identity_keys(resource, identity.name, @live)
        end

        for name <- field_names(resource) do
          assert ResourceInfo.relationship(resource, name, manifest) ==
                   ResourceInfo.relationship(resource, name, @live)

          assert ResourceInfo.public_relationship(resource, name, manifest) ==
                   ResourceInfo.public_relationship(resource, name, @live)
        end
      end
    end

    test "the pagination and read action behind every relationship", %{manifest: manifest} do
      for resource <- resources(),
          name <- Enum.map(Ash.Resource.Info.relationships(resource), & &1.name) do
        assert ResourceInfo.relationship_pagination(resource, name, manifest) ==
                 ResourceInfo.relationship_pagination(resource, name, @live),
               "relationship_pagination/3 disagreed for #{inspect(resource)}.#{name}"

        assert ResourceInfo.relationship_read_action(resource, name, manifest) ==
                 ResourceInfo.relationship_read_action(resource, name, @live),
               "relationship_read_action/3 disagreed for #{inspect(resource)}.#{name}"
      end
    end

    test "the fixture covers every pagination shape, so the test above is not vacuous",
         %{manifest: manifest} do
      library = AshIntrospection.Test.RelPagination.Library

      assert ResourceInfo.relationship_pagination(library, :books, manifest) == :offset
      assert ResourceInfo.relationship_pagination(library, :recent_books, manifest) == :keyset
      assert ResourceInfo.relationship_pagination(library, :journals, manifest) == :mixed
      assert ResourceInfo.relationship_pagination(library, :found_books, manifest) == :none

      # A defaulted read is not an unpaginated read: Ash fills pagination in
      # from the data layer, and ETS offers both kinds.
      assert ResourceInfo.relationship_pagination(library, :notes, manifest) == :mixed

      # These three share one destination and differ only in the
      # relationship's own `read_action`, so they are what prove the decorator
      # reads it rather than the destination's primary read.
      assert ResourceInfo.relationship_read_action(library, :books, manifest) == :read
      assert ResourceInfo.relationship_read_action(library, :found_books, manifest) == :find

      assert ResourceInfo.relationship_read_action(library, :recent_books, manifest) ==
               :list_keyset
    end

    test "a to-one relationship has no pagination", %{manifest: manifest} do
      assert ResourceInfo.relationship_pagination(AshIntrospection.Test.User, :address, manifest) ==
               :none
    end

    test "the bulk-authorization strategy", %{manifest: manifest} do
      for resource <- resources() do
        assert ResourceInfo.authorize_bulk_strategy(resource, manifest) ==
                 ResourceInfo.authorize_bulk_strategy(resource, @live)

        assert ResourceInfo.authorize_bulk_strategy(resource, manifest) in [:error, :filter]
      end
    end
  end

  describe "the modules built on the reader agree too" do
    test "ResourceFields returns the same {type, constraints} either way", %{manifest: manifest} do
      for resource <- resources(), name <- field_names(resource) do
        assert ResourceFields.get_field_type_info(resource, name, manifest) ==
                 ResourceFields.get_field_type_info(resource, name, @live),
               "get_field_type_info/3 disagreed for #{inspect(resource)}.#{name}"

        assert ResourceFields.get_public_field_type_info(resource, name, manifest) ==
                 ResourceFields.get_public_field_type_info(resource, name, @live),
               "get_public_field_type_info/3 disagreed for #{inspect(resource)}.#{name}"

        assert ResourceFields.get_aggregate_type_info(resource, name, manifest) ==
                 ResourceFields.get_aggregate_type_info(resource, name, @live),
               "get_aggregate_type_info/3 disagreed for #{inspect(resource)}.#{name}"
      end
    end

    test "ActionIntrospection classifies every action the same way", %{manifest: manifest} do
      alias AshIntrospection.Codegen.ActionIntrospection

      for resource <- resources(), action <- Ash.Resource.Info.actions(resource) do
        assert ActionIntrospection.action_input_type(resource, action, manifest) ==
                 ActionIntrospection.action_input_type(resource, action, @live),
               "action_input_type/3 disagreed for #{inspect(resource)}.#{action.name}"

        assert ActionIntrospection.get_required_inputs(resource, action, manifest) ==
                 ActionIntrospection.get_required_inputs(resource, action, @live)

        assert ActionIntrospection.get_optional_inputs(resource, action, manifest) ==
                 ActionIntrospection.get_optional_inputs(resource, action, @live)
      end
    end

    test "ActionIntrospection returns the classification it would have computed",
         %{manifest: manifest} do
      alias AshIntrospection.Codegen.ActionIntrospection

      # Compared against the same manifest, not against `@live`.
      # `classify_return_type/3` asks `ResourceInfo.declared_resource?/2`, whose
      # answer is scoped by the manifest on purpose — a struct returning an
      # undeclared resource classifies differently with and without one. What
      # decoration must not change is the answer for a given config.
      for resource <- resources(), action <- Ash.Resource.Info.actions(resource) do
        assert ActionIntrospection.action_return_classification(resource, action, manifest) ==
                 ActionIntrospection.action_returns_field_selectable_type?(action, manifest),
               "return classification disagreed for #{inspect(resource)}.#{action.name}"
      end
    end

    test "the fixture classifies more than one way, so the test above is not vacuous",
         %{manifest: manifest} do
      alias AshIntrospection.Codegen.ActionIntrospection

      classifications =
        for resource <- resources(),
            action <- Ash.Resource.Info.actions(resource),
            uniq: true do
          case ActionIntrospection.action_return_classification(resource, action, manifest) do
            {:ok, kind, _data} -> {:ok, kind}
            {:error, reason} -> {:error, reason}
          end
        end

      assert {:error, :not_generic_action} in classifications
      assert Enum.any?(classifications, &match?({:ok, _}, &1))
    end

    test "ValidationErrorTypes classifies the same inputs and attributes", %{manifest: manifest} do
      alias AshIntrospection.Codegen.ValidationErrorTypes

      for resource <- resources() do
        assert ValidationErrorTypes.classify_resource_attribute_errors(resource, manifest) ==
                 ValidationErrorTypes.classify_resource_attribute_errors(resource, @live)

        for action <- Ash.Resource.Info.actions(resource) do
          assert ValidationErrorTypes.classify_action_input_errors(resource, action, manifest) ==
                   ValidationErrorTypes.classify_action_input_errors(resource, action, @live),
                 "classify_action_input_errors/3 disagreed for " <>
                   "#{inspect(resource)}.#{action.name}"
        end
      end
    end
  end

  describe "the precomputed client names match what the pipeline would compute" do
    test "every field, under every built-in formatter", %{manifest: manifest} do
      source = Map.fetch!(manifest, :manifest)

      for resource <- resources() do
        entry =
          Map.get(source.resources, resource) || Map.get(source.types, resource).resource

        for name <- field_names(resource),
            formatter <- [:camel_case, :pascal_case, :snake_case] do
          assert Custom.formatted_field_name(entry, name, formatter, source.namespace) ==
                   AshIntrospection.FieldFormatter.format_field_name(name, formatter),
                 "#{inspect(resource)}.#{name} under #{formatter}"
        end
      end
    end

    test "every action argument, under every built-in formatter", %{manifest: manifest} do
      source = Map.fetch!(manifest, :manifest)

      checked =
        for resource <- resources(),
            action <- Ash.Resource.Info.actions(resource),
            argument <- action.arguments,
            formatter <- [:camel_case, :pascal_case, :snake_case] do
          entry =
            Map.get(source.resources, resource) || Map.get(source.types, resource).resource

          assert Custom.formatted_argument_name(
                   entry,
                   action.name,
                   argument.name,
                   formatter,
                   source.namespace
                 ) ==
                   AshIntrospection.FieldFormatter.format_field_name(argument.name, formatter),
                 "#{inspect(resource)}.#{action.name}(#{argument.name}) under #{formatter}"

          {resource, action.name, argument.name}
        end

      assert checked != [], "no fixture action takes an argument — this test is vacuous"
    end

    test "the reverse argument map inverts the forward one", %{manifest: manifest} do
      source = Map.fetch!(manifest, :manifest)

      for resource <- resources() do
        entry =
          Map.get(source.resources, resource) || Map.get(source.types, resource).resource

        for action <- Ash.Resource.Info.actions(resource),
            {argument, client_name} <-
              Custom.argument_name_mappings(entry, action.name, source.namespace) do
          assert Custom.original_argument_name(
                   entry,
                   action.name,
                   client_name,
                   source.namespace
                 ) == argument
        end
      end
    end

    test "the reverse map inverts the forward one", %{manifest: manifest} do
      source = Map.fetch!(manifest, :manifest)

      for resource <- resources() do
        entry =
          Map.get(source.resources, resource) || Map.get(source.types, resource).resource

        for {field, client_name} <- Custom.field_name_mappings(entry, source.namespace) do
          assert Custom.original_field_name(entry, client_name, source.namespace) == field
          assert Custom.mapped_field_name(entry, field, source.namespace) == client_name
        end
      end
    end
  end
end
