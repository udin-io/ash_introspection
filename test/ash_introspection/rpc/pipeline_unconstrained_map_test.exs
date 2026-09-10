# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineUnconstrainedMapTest do
  @moduledoc """
  Pins that a generic action returning an unconstrained `:map` hands its
  payload to the client untouched — every value, every key.

  An unconstrained `:map` is an explicit opt-out of typing. The pipeline has no
  field definitions to select against, so field selection must be skipped
  entirely and the map returned verbatim. #62 found the guard that skips it was
  dead: it asked for `action.constraints == []`, but `Ash.Type.Map` declares
  `preserve_nil_values?` with a default, so `Ash.Type.init/2` normalises every
  such action to `[preserve_nil_values?: false]` and the guard never matched.
  Every request fell through to the typed path, which looked up the requested
  field names in a map that does not use them and wrote `nil` for each miss —
  silent data loss, not a re-keying nit.

  `AshIntrospection.Test.AuditedRecord.raw_payload` is the fixture: an
  unconstrained `:map` whose keys are the caller's, including a leading
  underscore (`_id`) and a snake_case word (`field_name`) that a formatter
  would rewrite if it were allowed to.

  A casing assertion cannot see this bug, and neither can a template that
  happens to name the map's own keys. The requests below ask for field names
  the payload does not carry — which is what a generated client does — and
  assert the values, not the casing.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.AuditedRecord
  alias AshIntrospection.Test.MetadataDomain

  # The map the fixture's action hands back, verbatim.
  @raw_audit %{
    "_id" => "audit-1",
    "field_name" => "title",
    "nested" => %{"_rev" => "rev-7", "changed_by" => "ops-team"}
  }

  defp response(extraction_template) do
    request =
      %{
        domain: MetadataDomain,
        resource: AuditedRecord,
        action: Ash.Resource.Info.action(AuditedRecord, :raw_payload),
        rpc_action: %{},
        input: %{},
        context: %{},
        select: [],
        load: [],
        extraction_template: extraction_template,
        show_metadata: []
      }
      |> Request.new()

    {:ok, ash_result} = Pipeline.execute_ash_action(request)
    {:ok, processed} = Pipeline.process_result(ash_result, request)

    Pipeline.format_output_with_request(%{success: true, data: processed}, request)
  end

  describe "the premise" do
    test "ash normalises an unconstrained map action's constraints to a non-empty list" do
      action = Ash.Resource.Info.action(AuditedRecord, :raw_payload)

      assert action.returns == Ash.Type.Map
      assert action.constraints == [preserve_nil_values?: false]
      refute AshIntrospection.TypeSystem.Introspection.has_field_constraints?(action.constraints)
    end
  end

  describe "a generic action returning an unconstrained map" do
    test "hands the whole payload back when the client asks for names it does not carry" do
      assert %{"data" => @raw_audit, "success" => true} = response([:id, :name, :email])
    end

    test "keeps the keys the caller wrote, including a leading underscore" do
      %{"data" => data} = response([:id, :name, :email])

      assert Map.keys(data) |> Enum.sort() == ["_id", "field_name", "nested"]
      assert data["_id"] == "audit-1"
      assert data["field_name"] == "title"
    end

    test "leaves nested keys alone" do
      %{"data" => data} = response([:id, :name, :email])

      assert data["nested"] == %{"_rev" => "rev-7", "changed_by" => "ops-team"}
    end

    test "hands the whole payload back when the client asks for the map's own keys" do
      %{"data" => data} = response([:_id, :field_name, :nested])

      assert data == @raw_audit
    end

    test "hands the whole payload back when the client asks for nothing" do
      %{"data" => data} = response([])

      assert data == @raw_audit
    end
  end
end
