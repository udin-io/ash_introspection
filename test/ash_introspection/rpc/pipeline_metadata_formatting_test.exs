# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineMetadataFormattingTest do
  @moduledoc """
  Pins how action metadata reaches the client: formatted exactly once, and by
  the type the action declared for it.

  The read path used to merge metadata into the record raw, so the nested keys
  of a typed-map metadata value arrived in snake_case inside a response that
  was camelCase everywhere else. Found in #20 against upstream `ash_typescript`
  `8a05642`.

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
end
