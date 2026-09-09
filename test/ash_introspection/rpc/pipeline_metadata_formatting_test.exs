# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineMetadataFormattingTest do
  @moduledoc """
  Pins how action metadata reaches the client: formatted exactly once, and by
  the type the action declared for it.

  Three failures lived here, all found in #20 against upstream `ash_typescript`
  (`8a05642`, `9e5d05a`, `919e817`):

  - The read path merged metadata into the record raw, so the nested keys of a
    typed-map metadata value arrived in snake_case inside a response that was
    camelCase everywhere else.
  - The mutation path camelized the whole metadata map recursively, so a value
    the type system had already formatted was formatted a second time.
  - That same recursion renamed the keys inside an unconstrained `:map`. An
    unconstrained map is an explicit opt-out of typing: its keys belong to
    whoever wrote them and no formatter may touch them.

  `AshIntrospection.Test.RevisionInfo` is what makes a second formatting pass
  visible. Camelizing `changedBy` yields `changedBy` again, so double
  formatting hides in a plain field; `RevisionInfo` pins `:revision` to the
  client name `_rev`, and a second pass rewrites that to `rev`.

  Every assertion goes through the three public pipeline stages a client's
  response actually passes through — `execute_ash_action/1`,
  `process_result/3`, `format_output_with_request/3` — never a private helper.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.AuditedRecord
  alias AshIntrospection.Test.MetadataDomain

  @show_metadata [:audit_entry, :revision_info, :raw_audit]

  # The unconstrained map the fixture's actions hand back, verbatim. Its keys
  # are the caller's: a leading underscore, a snake_case word, and a nested map
  # carrying both. Every one of them is a key the camel-case formatter would
  # rewrite if it were allowed to.
  @raw_audit %{
    "_id" => "audit-1",
    "field_name" => "title",
    "nested" => %{"_rev" => "rev-7", "changed_by" => "ops-team"}
  }

  defp request(overrides) do
    %{
      domain: MetadataDomain,
      resource: AuditedRecord,
      rpc_action: %{},
      input: %{},
      context: %{},
      select: [:id, :title],
      load: [],
      extraction_template: [:id, :title],
      show_metadata: @show_metadata
    }
    |> Map.merge(overrides)
    |> Request.new()
  end

  defp response(request) do
    {:ok, ash_result} = Pipeline.execute_ash_action(request)
    {:ok, processed} = Pipeline.process_result(ash_result, request)
    Pipeline.format_output_with_request(%{success: true, data: processed}, request)
  end

  defp create_record(title) do
    AuditedRecord
    |> Ash.Changeset.for_create(:create, %{title: title})
    |> Ash.create!()
  end

  defp read_response do
    record = create_record("read-#{System.unique_integer([:positive])}")

    request(%{
      action: Ash.Resource.Info.action(AuditedRecord, :read_with_metadata),
      get_by: %{id: record.id}
    })
    |> response()
  end

  defp mutation_metadata(overrides \\ %{}) do
    base = %{
      action: Ash.Resource.Info.action(AuditedRecord, :create_with_metadata),
      input: %{title: "create-#{System.unique_integer([:positive])}"}
    }

    %{"metadata" => metadata} = base |> Map.merge(overrides) |> request() |> response()

    metadata
  end

  describe "read action metadata" do
    test "the nested keys of a typed map metadata value are camelized" do
      %{"data" => data} = read_response()

      assert %{"changedBy" => "ops-team", "changeReason" => "nightly cleanup"} ==
               data["auditEntry"]
    end

    test "a client name pinned by the declared type survives the formatter" do
      %{"data" => data} = read_response()

      assert %{"_rev" => "rev-7", "revisedBy" => "ops-team"} == data["revisionInfo"]
    end
  end

  describe "mutation action metadata" do
    test "the nested keys of a typed map metadata value are camelized" do
      assert %{"changedBy" => "ops-team", "changeReason" => "nightly cleanup"} ==
               mutation_metadata()["auditEntry"]
    end

    test "a client name pinned by the declared type survives the formatter" do
      assert %{"_rev" => "rev-7", "revisedBy" => "ops-team"} ==
               mutation_metadata()["revisionInfo"]
    end

    test "only the metadata fields the request asked for reach the client" do
      assert ["revisionInfo"] ==
               Map.keys(mutation_metadata(%{show_metadata: [:revision_info]}))
    end
  end

  describe "unconstrained maps" do
    test "a read leaves the keys of an unconstrained map metadata value alone" do
      %{"data" => data} = read_response()

      assert @raw_audit == data["rawAudit"]
    end

    test "a mutation leaves the keys of an unconstrained map metadata value alone" do
      assert @raw_audit == mutation_metadata()["rawAudit"]
    end

    test "a generic action returning an unconstrained map hands its keys back" do
      assert %{"data" => @raw_audit} =
               request(%{
                 action: Ash.Resource.Info.action(AuditedRecord, :raw_payload),
                 select: [],
                 extraction_template: [],
                 show_metadata: []
               })
               |> response()
    end
  end
end
