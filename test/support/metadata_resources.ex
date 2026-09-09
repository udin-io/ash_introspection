# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.RevisionInfo do
  @moduledoc """
  A typed map whose interop names are deliberately not camelCase.

  `:revision` is exposed as `_rev`, a wire name a client pins rather than
  derives. Running the camel-case formatter over `_rev` a second time rewrites
  it to `rev`, which is the whole reason this type exists here: it turns a
  double formatting pass from a silent no-op into an observable renaming. See
  `test/ash_introspection/rpc/pipeline_metadata_formatting_test.exs`.
  """
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        revision: [type: :string],
        revised_by: [type: :string]
      ]
    ]

  @doc "Field name mappings for interop (TypeScript, Kotlin, etc.)."
  def interop_field_names do
    [revision: "_rev", revised_by: "revisedBy"]
  end
end

defmodule AshIntrospection.Test.MetadataDomain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource AshIntrospection.Test.AuditedRecord
  end
end

defmodule AshIntrospection.Test.AuditedRecord do
  @moduledoc """
  Resource for exercising action metadata formatting on the read and the
  mutation path.

  It declares the three metadata shapes that format differently:

  - `:audit_entry` is a typed map, so its nested keys are the library's to
    camelize.
  - `:revision_info` is a NewType carrying `interop_field_names/0`, so its
    client names are pinned and must survive untouched.
  - `:raw_audit` is an unconstrained `:map`, an explicit opt-out of typing, so
    its keys belong to whoever wrote them and must reach the client verbatim.

  `:raw_payload` is the same opt-out expressed as a generic action's return
  type rather than as metadata.
  """
  use Ash.Resource,
    domain: AshIntrospection.Test.MetadataDomain,
    data_layer: Ash.DataLayer.Ets

  @audit_entry %{changed_by: "ops-team", change_reason: "nightly cleanup"}
  @revision_info %{revision: "rev-7", revised_by: "ops-team"}
  @raw_audit %{
    "_id" => "audit-1",
    "field_name" => "title",
    "nested" => %{"_rev" => "rev-7", "changed_by" => "ops-team"}
  }

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:title]
    end

    read :read_with_metadata do
      get? true

      metadata :audit_entry, :map,
        constraints: [
          fields: [
            changed_by: [type: :string],
            change_reason: [type: :string]
          ]
        ]

      metadata :revision_info, AshIntrospection.Test.RevisionInfo
      metadata :raw_audit, :map

      prepare fn query, _context ->
        Ash.Query.after_action(query, fn _query, records ->
          {:ok, Enum.map(records, &AshIntrospection.Test.AuditedRecord.put_test_metadata/1)}
        end)
      end
    end

    create :create_with_metadata do
      accept [:title]

      metadata :audit_entry, :map,
        constraints: [
          fields: [
            changed_by: [type: :string],
            change_reason: [type: :string]
          ]
        ]

      metadata :revision_info, AshIntrospection.Test.RevisionInfo
      metadata :raw_audit, :map

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, record ->
          {:ok, AshIntrospection.Test.AuditedRecord.put_test_metadata(record)}
        end)
      end
    end

    action :raw_payload, :map do
      run fn _input, _context -> {:ok, AshIntrospection.Test.AuditedRecord.raw_audit()} end
    end
  end

  @doc "The unconstrained map every action here hands back, keys and all."
  def raw_audit, do: @raw_audit

  @doc "Attaches the three metadata shapes this resource's actions declare."
  def put_test_metadata(record) do
    record
    |> Ash.Resource.put_metadata(:audit_entry, @audit_entry)
    |> Ash.Resource.put_metadata(:revision_info, @revision_info)
    |> Ash.Resource.put_metadata(:raw_audit, @raw_audit)
  end
end
