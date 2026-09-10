# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineListOutputTest do
  @moduledoc """
  Pins that stage 4 formats a read result carrying more than one record.

  #57: `format_output_with_request/3` formatted nothing when the result was a
  plain list. `ValueFormatter.format_resource/4` guards on `is_map(value) and
  not is_struct(value)`, and `format/5` only unwraps an array when the *type*
  is `{:array, _}` — but `Pipeline.format_action_output/5` hands it the bare
  resource module. Neither path matched a list, so an unpaginated read returned
  internal atom keys to the client.

  The paginated read is the same bug one level down and it was only ever
  read off the code. Measured on `main` at `51a9c27`: an `%Ash.Page.Offset{}`
  reaches stage 4 as a map, so `format_resource/4` does match and camelizes the
  envelope — `hasMore` came back correctly — but `:results` is not a field on
  the resource, so `ResourceFields.get_field_type_info/2` answers `{nil, []}`
  and every record inside the page came back with atom keys. Both shapes are
  covered here.

  Single-record `get?` reads were always correct, which is why nothing caught
  this: every RPC fixture in the suite read one record. `:get_entry` is here as
  the control.

  The assertions name the values, not just the casing, and they name **every**
  element. A list whose first record is right and whose second is not is the
  failure a `List.first/1` assertion cannot see.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.LedgerEntry
  alias AshIntrospection.Test.ListOutputDomain

  setup do
    entries =
      for {name, amount} <- [{"alpha ledger", 10}, {"beta ledger", 20}, {"gamma ledger", 30}] do
        LedgerEntry
        |> Ash.Changeset.for_create(:create, %{account_name: name, entry_amount: amount})
        |> Ash.create!()
      end

    %{entries: entries}
  end

  defp response(action_name, overrides \\ %{}) do
    request =
      %{
        domain: ListOutputDomain,
        resource: LedgerEntry,
        action: Ash.Resource.Info.action(LedgerEntry, action_name),
        rpc_action: %{},
        input: %{},
        context: %{},
        select: [:id, :account_name, :entry_amount],
        load: [],
        extraction_template: [:id, :account_name, :entry_amount],
        show_metadata: []
      }
      |> Map.merge(overrides)
      |> Request.new()

    {:ok, ash_result} = Pipeline.execute_ash_action(request)
    {:ok, processed} = Pipeline.process_result(ash_result, request)

    Pipeline.format_output_with_request(%{success: true, data: processed}, request)
  end

  describe "an unpaginated read returning several records" do
    test "formats every record, not the first one" do
      %{"data" => records} = response(:list_entries)

      assert [alpha, beta, gamma] = records

      assert %{"accountName" => "alpha ledger", "entryAmount" => 10} = alpha
      assert %{"accountName" => "beta ledger", "entryAmount" => 20} = beta
      assert %{"accountName" => "gamma ledger", "entryAmount" => 30} = gamma
    end

    test "leaves no internal atom key anywhere in the list" do
      %{"data" => records} = response(:list_entries)

      for record <- records do
        assert Enum.sort(Map.keys(record)) == ["accountName", "entryAmount", "id"]
      end
    end

    test "carries each record's id through", %{entries: entries} do
      %{"data" => records} = response(:list_entries)

      returned_ids = records |> Enum.map(& &1["id"]) |> Enum.sort()
      assert returned_ids == entries |> Enum.map(& &1.id) |> Enum.sort()
    end

    test "returns an empty list as an empty list" do
      LedgerEntry |> Ash.read!() |> Enum.each(&Ash.destroy!/1)

      assert %{"data" => []} = response(:list_entries)
    end
  end

  describe "a paginated read" do
    test "formats the records inside the page, not only the page envelope" do
      %{"data" => page} = response(:paged_entries, %{pagination: %{limit: 2, offset: 0}})

      assert [alpha, beta] = page["results"]
      assert %{"accountName" => "alpha ledger", "entryAmount" => 10} = alpha
      assert %{"accountName" => "beta ledger", "entryAmount" => 20} = beta
    end

    test "leaves no internal atom key inside the page's records" do
      %{"data" => page} = response(:paged_entries, %{pagination: %{limit: 3, offset: 0}})

      for record <- page["results"] do
        assert Enum.sort(Map.keys(record)) == ["accountName", "entryAmount", "id"]
      end
    end

    test "keeps the page envelope it already formatted" do
      %{"data" => page} = response(:paged_entries, %{pagination: %{limit: 2, offset: 0}})

      assert page["limit"] == 2
      assert page["offset"] == 0
      assert page["hasMore"] == true
    end

    test "formats the second page's records too" do
      %{"data" => page} = response(:paged_entries, %{pagination: %{limit: 2, offset: 2}})

      assert [gamma] = page["results"]
      assert %{"accountName" => "gamma ledger", "entryAmount" => 30} = gamma
    end
  end

  describe "the single-record path #57 never broke" do
    test "a get? read still formats its one record", %{entries: [alpha | _]} do
      %{"data" => record} =
        response(:get_entry, %{get_by: %{account_name: "alpha ledger"}})

      assert record["id"] == alpha.id
      assert record["accountName"] == "alpha ledger"
      assert record["entryAmount"] == 10
    end
  end
end
