# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.ListOutputDomain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(AshIntrospection.Test.LedgerEntry)
  end
end

defmodule AshIntrospection.Test.LedgerEntry do
  @moduledoc """
  Resource for exercising stage 4 on results that are **more than one record**.

  Every other RPC fixture here reads a single record through a `get?` action,
  which is exactly the shape `ValueFormatter.format_resource/4` already
  matched, so #57 — a plain list reaching the client with internal atom keys —
  survived a full test suite. This resource carries the three read shapes stage
  4 has to tell apart:

  - `:list_entries` is an ordinary read, so the result is a bare list.
  - `:paged_entries` requires offset pagination, so the result is an
    `%Ash.Page.Offset{}` that stage 3 flattens into a map with `:results`.
  - `:get_entry` is the single-record `get?` read, here as the control that
    proves the path which always worked still works.

  Attribute names are snake_case (`account_name`, `entry_amount`) so a missing
  format pass is visible as an atom key, and the values are distinct per record
  so a test can assert that each one survived rather than only that the first
  one is shaped right.

  `:raw_rows` is #64: a generic action returning an unconstrained
  `{:array, :map}`. Its maps carry the caller's own keys — a leading
  underscore (`_id`) and a snake_case word (`field_name`) — which the typed
  path rewrites or nils out.  `:typed_rows` is its control: the same array
  shape with real `items: [fields: ...]` constraints, which must keep going
  through the typed path.

  `private? true` on the ETS table for the reason `Test.Account` has it — see
  #55 and the note in `CLAUDE.md`. Writes must stay in the test process.
  """
  use Ash.Resource,
    domain: AshIntrospection.Test.ListOutputDomain,
    data_layer: Ash.DataLayer.Ets

  @raw_rows [
    %{"_id" => "a-1", "name" => "KSR", "nested" => %{"_rev" => "rev-1"}},
    %{"_id" => "a-2", "name" => "Ivy", "nested" => %{"_rev" => "rev-2"}}
  ]

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:account_name, :string, allow_nil?: false, public?: true)
    attribute(:entry_amount, :integer, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:account_name, :entry_amount])
    end

    read :list_entries do
      prepare(build(sort: [entry_amount: :asc]))
    end

    read :paged_entries do
      pagination(offset?: true, required?: true, default_limit: 10, countable: true)
      prepare(build(sort: [entry_amount: :asc]))
    end

    read :get_entry do
      get?(true)
    end

    action :raw_rows, {:array, :map} do
      run(fn _input, _context -> {:ok, AshIntrospection.Test.LedgerEntry.raw_rows()} end)
    end

    action :typed_rows, {:array, :map} do
      constraints(items: [fields: [row_id: [type: :string], row_label: [type: :string]]])

      run(fn _input, _context ->
        {:ok, [%{row_id: "t-1", row_label: "first"}, %{row_id: "t-2", row_label: "second"}]}
      end)
    end
  end

  @doc "The untyped rows `:raw_rows` hands back, keys and all."
  def raw_rows, do: @raw_rows
end
