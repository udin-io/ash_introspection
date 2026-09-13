# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Manifest.CodegenDifferentialTest do
  @moduledoc """
  Runs every public function of `AshIntrospection.Codegen.TypeDiscovery` twice
  over `test/support/` — once against live `Ash.Resource.Info`, once against a
  decorated `%Ash.Info.Manifest{}` — and asserts the two results are byte for
  byte the same term.

  Issue #23 stage 4 deletes `Codegen.TypeDiscovery` and generates against the
  manifest alone. This is the half of that stage which deletes nothing: it
  makes codegen read the manifest, and proves the manifest already answers
  everything the traversal asks, before anything depends on it. Stage 3 shipped
  in `ash_kotlin_multiplatform` (its PR #75, `e5ad024`), so a manifest now
  exists in production and nothing reads it on the request path. This is where
  that assumption first becomes load-bearing.

  ## Byte for byte, and why that wording is literal

  `identical!/3` compares `:erlang.term_to_binary/1` of both results, not the
  terms. Discovery output is ordered — a generator emits declarations in the
  order it is handed — so a comparison that tolerated reordering would pass on
  a result no consumer could use. Set equality is not the property under test.

  ## Why this cannot pass vacuously

  Four guards, in `describe "the guards"` below.

    * **The manifest config carries no callbacks at all.** `get_rpc_resources`
      is what the live path fetches with `Map.fetch!/2`, so the same call
      raises `KeyError` without a manifest. A reader that ignored the manifest
      could not answer these questions; it would crash.
    * **Scoping is observable.** A manifest that does not carry a resource must
      stop the traversal at it, where live introspection walks straight in.
      One assertion pins that difference rather than averaging it away.
    * **Every compared result is checked for content.** The readers that
      return a list are asserted non-empty and asserted to contain named
      fixtures, so no pair of `[]` counts as agreement.
    * **Each test asserts how many comparisons it made.** A traversal that
      silently stopped enumerating would drop the count below its floor.

  ## How many comparisons

  423 as of this commit, over 22 fixture resources and 23 entrypoints: 6
  whole-application readers, 2 warning strings, 110 per-resource reads (22
  resources by 5 readers), 134 type traversals (67 fields, each direct and
  wrapped in an array), 1 `fields` keyword list, 101 actions scanned for struct
  arguments, and 69 entrypoint-scoped discoveries (23 by 3 readers). The counts
  are asserted, not commented: a fixture gained or lost moves them, and the
  assertion is what says so.

  One of those is thin and named here rather than hidden: `traverse_fields/2`
  has exactly one fixture, `Test.Dossier.owner`. It is the only attribute in
  `test/support/` whose constraints carry a `:fields` keyword list.
  """

  use ExUnit.Case, async: true

  alias AshIntrospection.Codegen.TypeDiscovery
  alias AshIntrospection.Test
  alias AshIntrospection.Test.ManifestFixture

  @otp_app :ash_introspection

  setup_all do
    %{
      live: live_config(),
      manifest: ManifestFixture.decorated_config()
    }
  end

  # The live path is handed the entrypoints in the order the manifest carries
  # them. That order is an input to discovery, not an output of it, and holding
  # an input constant is what makes the rest of this file a test of the reader
  # rather than a test of `Ash.Info.Manifest.Generator`'s sort. The one place
  # the orders differ is asserted on purpose in "the orderings" below.
  defp live_config do
    entrypoints = ManifestFixture.manifest_entrypoints()
    resources = entrypoints |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    %{
      get_rpc_resources: fn @otp_app -> resources end,
      get_rpc_action_entrypoints: fn @otp_app -> entrypoints end
    }
  end

  defp resources do
    ManifestFixture.resource_modules() ++ ManifestFixture.embedded_modules()
  end

  defp fields(resource) do
    Ash.Resource.Info.attributes(resource) ++
      Ash.Resource.Info.calculations(resource) ++
      Ash.Resource.Info.aggregates(resource)
  end

  # Asserts the two results are the same term, byte for byte, and counts as one
  # comparison.
  defp identical!(label, live_result, manifest_result) do
    assert :erlang.term_to_binary(live_result) == :erlang.term_to_binary(manifest_result),
           """
           #{label} differed.

           live:     #{inspect(live_result, pretty: true, limit: :infinity)}
           manifest: #{inspect(manifest_result, pretty: true, limit: :infinity)}
           """

    1
  end

  describe "the guards" do
    test "the manifest answers with no callbacks, which the live path cannot", %{
      live: live,
      manifest: manifest
    } do
      # `get_rpc_resources` is the key the live path fetches to find its
      # entrypoints. The manifest config below has neither callback on it, so
      # every answer in this file comes from `manifest.entrypoints` or from
      # nowhere.
      refute Map.has_key?(manifest, :get_rpc_resources)
      refute Map.has_key?(manifest, :get_rpc_action_entrypoints)

      assert_raise KeyError, fn -> TypeDiscovery.find_embedded_resources(@otp_app, %{}) end

      assert TypeDiscovery.find_embedded_resources(@otp_app, manifest) ==
               TypeDiscovery.find_embedded_resources(@otp_app, live)
    end

    test "a manifest that does not declare a resource stops the traversal at it" do
      # The single input whose answer must differ. `Test.User` is a resource by
      # every live measure and is absent from a manifest scoped to Ledger, so a
      # reader that ignored its manifest would walk into it here.
      scoped = ManifestFixture.scoped_config([{Test.Ledger, :read}])
      struct_type = [instance_of: Test.User]

      assert TypeDiscovery.traverse_type(Ash.Type.Struct, struct_type, %{}) == [Test.User]
      assert TypeDiscovery.traverse_type(Ash.Type.Struct, struct_type, scoped) == []
    end

    test "the compared results carry content", %{live: live, manifest: manifest} do
      embedded = TypeDiscovery.find_embedded_resources(@otp_app, manifest)

      assert Test.EmbeddedNote in embedded
      assert Test.EmbeddedFilter in embedded
      assert Test.EmbeddedAudit in embedded
      assert Test.EmbeddedAttachment in embedded
      assert Test.EmbeddedRendered in embedded
      assert Test.EmbeddedUnscoped in embedded
      assert length(embedded) >= 6

      assert Test.User in TypeDiscovery.scan_rpc_resources(@otp_app, manifest)
      assert Test.User in TypeDiscovery.scan_rpc_resources(@otp_app, live)

      # The readers that had no non-empty fixture before `Test.Dossier`.
      assert TypeDiscovery.find_field_constrained_types([Test.Dossier], manifest) != []
      assert TypeDiscovery.find_referenced_resources(Test.Dossier, manifest) == [Test.User]
    end

    test "every fixture resource reaches this file decorated", %{manifest: manifest} do
      source = Map.fetch!(manifest, :manifest)

      for resource <- resources() do
        entry = Map.get(source.resources, resource) || Map.get(source.types, resource).resource

        assert AshIntrospection.Manifest.Custom.decorated?(entry, source.namespace),
               "#{inspect(resource)} is undecorated, so its reads fell back to live"
      end
    end
  end

  describe "whole-application discovery agrees" do
    test "every reader that takes an otp_app", %{live: live, manifest: manifest} do
      compared =
        identical!(
          "scan_rpc_resources/2",
          TypeDiscovery.scan_rpc_resources(@otp_app, live),
          TypeDiscovery.scan_rpc_resources(@otp_app, manifest)
        ) +
          identical!(
            "find_embedded_resources/2",
            TypeDiscovery.find_embedded_resources(@otp_app, live),
            TypeDiscovery.find_embedded_resources(@otp_app, manifest)
          ) +
          identical!(
            "find_non_rpc_referenced_resources/2",
            TypeDiscovery.find_non_rpc_referenced_resources(@otp_app, live),
            TypeDiscovery.find_non_rpc_referenced_resources(@otp_app, manifest)
          ) +
          identical!(
            "find_non_rpc_referenced_resources_with_paths/2",
            TypeDiscovery.find_non_rpc_referenced_resources_with_paths(@otp_app, live),
            TypeDiscovery.find_non_rpc_referenced_resources_with_paths(@otp_app, manifest)
          ) +
          identical!(
            "find_resources_missing_from_rpc_config/2",
            TypeDiscovery.find_resources_missing_from_rpc_config(@otp_app, live),
            TypeDiscovery.find_resources_missing_from_rpc_config(@otp_app, manifest)
          ) +
          identical!(
            "find_field_constrained_types/2",
            TypeDiscovery.find_field_constrained_types(resources(), live),
            TypeDiscovery.find_field_constrained_types(resources(), manifest)
          )

      assert compared == 6
    end

    test "the warning both paths would print", %{live: live, manifest: manifest} do
      missing = TypeDiscovery.find_resources_missing_from_rpc_config(@otp_app, manifest)
      referenced = TypeDiscovery.find_non_rpc_referenced_resources_with_paths(@otp_app, manifest)

      compared =
        identical!(
          "build_missing_config_warning/3",
          TypeDiscovery.build_missing_config_warning(@otp_app, missing, live),
          TypeDiscovery.build_missing_config_warning(@otp_app, missing, manifest)
        ) +
          identical!(
            "build_non_rpc_references_warning/2",
            TypeDiscovery.build_non_rpc_references_warning(referenced, live),
            TypeDiscovery.build_non_rpc_references_warning(referenced, manifest)
          )

      assert compared == 2
    end
  end

  describe "per-resource discovery agrees" do
    test "the four readers that take one resource", %{live: live, manifest: manifest} do
      compared =
        for resource <- resources(), reduce: 0 do
          count ->
            count +
              identical!(
                "find_referenced_resources/2 #{inspect(resource)}",
                TypeDiscovery.find_referenced_resources(resource, live),
                TypeDiscovery.find_referenced_resources(resource, manifest)
              ) +
              identical!(
                "find_referenced_embedded_resources/2 #{inspect(resource)}",
                TypeDiscovery.find_referenced_embedded_resources(resource, live),
                TypeDiscovery.find_referenced_embedded_resources(resource, manifest)
              ) +
              identical!(
                "find_referenced_non_embedded_resources/2 #{inspect(resource)}",
                TypeDiscovery.find_referenced_non_embedded_resources(resource, live),
                TypeDiscovery.find_referenced_non_embedded_resources(resource, manifest)
              ) +
              identical!(
                "scan_rpc_resource/3 #{inspect(resource)}",
                TypeDiscovery.scan_rpc_resource(resource, MapSet.new(), live),
                TypeDiscovery.scan_rpc_resource(resource, MapSet.new(), manifest)
              ) +
              identical!(
                "find_field_constrained_types/2 #{inspect(resource)}",
                TypeDiscovery.find_field_constrained_types([resource], live),
                TypeDiscovery.find_field_constrained_types([resource], manifest)
              )
        end

      assert compared == length(resources()) * 5
      assert compared >= 110
    end
  end

  describe "per-type traversal agrees" do
    test "every attribute, calculation and aggregate of every fixture resource", %{
      live: live,
      manifest: manifest
    } do
      compared =
        for resource <- resources(), field <- fields(resource), reduce: 0 do
          count ->
            constraints = field.constraints || []

            count +
              identical!(
                "traverse_type/3 #{inspect(resource)}.#{field.name}",
                TypeDiscovery.traverse_type(field.type, constraints, live),
                TypeDiscovery.traverse_type(field.type, constraints, manifest)
              ) +
              identical!(
                "traverse_type/3 {:array, _} #{inspect(resource)}.#{field.name}",
                TypeDiscovery.traverse_type({:array, field.type}, [items: constraints], live),
                TypeDiscovery.traverse_type({:array, field.type}, [items: constraints], manifest)
              )
        end

      assert compared == Enum.sum(Enum.map(resources(), &length(fields(&1)))) * 2
      assert compared >= 134
    end

    test "every fields keyword list a fixture attribute carries", %{
      live: live,
      manifest: manifest
    } do
      field_lists =
        for resource <- resources(),
            field <- fields(resource),
            fields_constraint = Keyword.get(field.constraints || [], :fields),
            is_list(fields_constraint) do
          {resource, field.name, fields_constraint}
        end

      compared =
        for {resource, name, list} <- field_lists, reduce: 0 do
          count ->
            count +
              identical!(
                "traverse_fields/2 #{inspect(resource)}.#{name}",
                TypeDiscovery.traverse_fields(list, live),
                TypeDiscovery.traverse_fields(list, manifest)
              )
        end

      assert compared == length(field_lists)
      assert compared >= 1, "no fixture attribute carries a :fields constraint"
    end

    test "every action's struct arguments", %{live: live, manifest: manifest} do
      actions =
        for resource <- resources(), action <- Ash.Resource.Info.actions(resource), do: action

      compared =
        for action <- actions, reduce: 0 do
          count ->
            count +
              identical!(
                "find_struct_argument_resources/2 #{action.name}",
                TypeDiscovery.find_struct_argument_resources([action], live),
                TypeDiscovery.find_struct_argument_resources([action], manifest)
              )
        end

      assert compared == length(actions)
      assert compared >= 80

      # Non-vacuous: at least one action really does name a resource.
      attach = Ash.Resource.Info.action(Test.Document, :attach)
      found = TypeDiscovery.find_struct_argument_resources([attach], manifest)
      assert Test.EmbeddedAttachment in found
      assert Test.User in found
    end
  end

  describe "entrypoint-scoped discovery agrees" do
    test "one entrypoint at a time, manifest against callback" do
      compared =
        for {resource, action} <- ManifestFixture.entrypoints(), reduce: 0 do
          count ->
            scoped = ManifestFixture.scoped_config([{resource, action}])

            live = %{
              get_rpc_resources: fn @otp_app -> [resource] end,
              get_rpc_action_entrypoints: fn @otp_app -> [{resource, action}] end
            }

            label = "#{inspect(resource)}.#{action}"

            count +
              identical!(
                "scan_rpc_resources/2 scoped to #{label}",
                TypeDiscovery.scan_rpc_resources(@otp_app, live),
                TypeDiscovery.scan_rpc_resources(@otp_app, scoped)
              ) +
              identical!(
                "find_embedded_resources/2 scoped to #{label}",
                TypeDiscovery.find_embedded_resources(@otp_app, live),
                TypeDiscovery.find_embedded_resources(@otp_app, scoped)
              ) +
              identical!(
                "find_non_rpc_referenced_resources_with_paths/2 scoped to #{label}",
                TypeDiscovery.find_non_rpc_referenced_resources_with_paths(@otp_app, live),
                TypeDiscovery.find_non_rpc_referenced_resources_with_paths(@otp_app, scoped)
              )
        end

      assert compared == length(ManifestFixture.entrypoints()) * 3
      assert compared >= 69
    end

    test "a generic-action entrypoint still scopes out the resource's own fields" do
      # The #21 behaviour, re-asserted on the manifest path: a generic action
      # reaches only what it names, so Ledger's embedded attribute stays out.
      generic = ManifestFixture.scoped_config([{Test.Ledger, :ping}])
      read = ManifestFixture.scoped_config([{Test.Ledger, :read}])

      refute Test.EmbeddedUnscoped in TypeDiscovery.find_embedded_resources(@otp_app, generic)
      assert Test.EmbeddedUnscoped in TypeDiscovery.find_embedded_resources(@otp_app, read)
    end

    test "a resource referenced but never exposed is reported by both paths" do
      scoped = ManifestFixture.scoped_config([{Test.Dossier, :read}])

      live = %{
        get_rpc_resources: fn @otp_app -> [Test.Dossier] end,
        get_rpc_action_entrypoints: fn @otp_app -> [{Test.Dossier, :read}] end
      }

      expected = %{Test.User => ["Dossier -> owner"]}

      assert TypeDiscovery.find_non_rpc_referenced_resources_with_paths(@otp_app, live) ==
               expected

      assert TypeDiscovery.find_non_rpc_referenced_resources_with_paths(@otp_app, scoped) ==
               expected
    end
  end

  describe "the orderings" do
    test "the manifest sorts entrypoints and a callback does not" do
      # The one place the two paths return different terms for the same
      # question, and it is an input difference, not a reader difference:
      # `Ash.Info.Manifest.Generator` sorts entrypoints by resource module and
      # action name (`deps/ash/lib/ash/info/manifest/generator.ex:239`), a
      # consumer's DSL declares them in its own order, and discovery output is
      # ordered by its entrypoints. See docs/decisions.md.
      declared = ManifestFixture.entrypoints()
      sorted = ManifestFixture.manifest_entrypoints()

      assert Enum.sort(declared) == Enum.sort(sorted)
      refute declared == sorted

      declared_config = %{
        get_rpc_resources: fn @otp_app -> declared |> Enum.map(&elem(&1, 0)) |> Enum.uniq() end,
        get_rpc_action_entrypoints: fn @otp_app -> declared end
      }

      manifest = ManifestFixture.decorated_config()

      from_declaration = TypeDiscovery.scan_rpc_resources(@otp_app, declared_config)
      from_manifest = TypeDiscovery.scan_rpc_resources(@otp_app, manifest)

      assert Enum.sort(from_declaration) == Enum.sort(from_manifest)
      refute from_declaration == from_manifest
    end
  end
end
