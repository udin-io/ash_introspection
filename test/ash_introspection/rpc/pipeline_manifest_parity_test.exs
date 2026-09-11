# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineManifestParityTest do
  @moduledoc """
  The same request, run twice: once with no `:manifest` key and once with one.
  Both must produce the same bytes.

  `test/ash_introspection/resource_info_test.exs` proves the two sources agree
  at the reader. This proves the config key actually reaches it. Stage 3 of the
  pipeline builds `processor_config` from scratch rather than passing `config`
  through, so a key the build does not name is dropped before `ResultProcessor`
  ever sees it — the pipeline would then read a manifest in stages 1 and 4 and
  live introspection in stage 3, and nothing at the reader could tell.

  Three result shapes, because a read has three and #57 was the bug a fixture
  reading one record could not see: a bare list, an `%Ash.Page.Offset{}`, and a
  `get?` single record. Plus a named-identity update, which is the only path
  through `ResourceInfo.identity_keys/3`.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.FieldProcessing.FieldSelector
  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.Account
  alias AshIntrospection.Test.LedgerEntry
  alias AshIntrospection.Test.ListOutputDomain
  alias AshIntrospection.Test
  alias AshIntrospection.Test.ManifestFixture
  alias AshIntrospection.Test.RpcDomain

  setup do
    for {name, amount} <- [{"alpha ledger", 10}, {"beta ledger", 20}, {"gamma ledger", 30}] do
      LedgerEntry
      |> Ash.Changeset.for_create(:create, %{account_name: name, entry_amount: amount})
      |> Ash.create!()
    end

    :ok
  end

  defp ledger_request(action_name, overrides \\ %{}) do
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
  end

  defp run(request, config) do
    {:ok, ash_result} = Pipeline.execute_ash_action(request, config)
    {:ok, processed} = Pipeline.process_result(ash_result, request, config)
    Pipeline.format_output_with_request(%{success: true, data: processed}, request, config)
  end

  # Records carry generated ids and the ETS layer does not order reads, so the
  # two runs are compared on the field names and values that are stable, not on
  # the raw structures.
  defp comparable(%{"data" => data} = response) do
    Map.put(response, "data", comparable_data(data))
  end

  defp comparable_data(data) when is_list(data),
    do: Enum.sort_by(data, &Map.get(&1, "accountName"))

  defp comparable_data(%{"results" => results} = page),
    do: Map.put(page, "results", comparable_data(results))

  defp comparable_data(data), do: data

  describe "a manifest changes nothing the client can see" do
    test "a bare list read" do
      request = ledger_request(:list_entries)

      assert comparable(run(request, %{})) ==
               comparable(run(request, ManifestFixture.config()))
    end

    test "an offset-paginated read" do
      request = ledger_request(:paged_entries, %{input: %{}})

      with_manifest = run(request, ManifestFixture.config())
      without = run(request, %{})

      assert comparable(without) == comparable(with_manifest)
      assert %{"results" => [_ | _]} = with_manifest["data"]
    end

    test "a get? single-record read" do
      request = ledger_request(:get_entry, %{get_by: %{account_name: "alpha ledger"}})

      assert run(request, %{}) == run(request, ManifestFixture.config())
    end

    test "a named-identity update resolves the same record either way" do
      for config <- [%{}, ManifestFixture.config()] do
        suffix = System.unique_integer([:positive])

        account =
          Account
          |> Ash.Changeset.for_create(:create, %{
            name: "Parity-#{suffix}",
            email: "parity-#{suffix}@example.com",
            active: false
          })
          |> Ash.create!()

        request =
          Request.new(%{
            domain: RpcDomain,
            resource: Account,
            action: Ash.Resource.Info.action(Account, :update),
            rpc_action: %{identities: [:unique_name_active]},
            input: %{email: "moved-#{suffix}@example.com"},
            context: %{},
            select: [:id, :name, :email, :active],
            load: [],
            extraction_template: [:id, :name, :email, :active],
            identity: %{name: account.name, active: false}
          })

        response = run(request, config)

        assert response["data"]["id"] == account.id
        assert response["data"]["email"] == "moved-#{suffix}@example.com"
      end
    end
  end

  describe "field selection picks the same fields either way" do
    # FieldSelector is where ResourceInfo.relationship/3 and
    # public_relationship/3 are actually called with a config, and LedgerEntry
    # has no relationships — so the relationship path needs its own fixture.
    test "a nested relationship, a calculation and an aggregate" do
      for {resource, action, fields} <- [
            {Test.User, :read, [:id, :name, :address_count, %{"address" => [:id, :street]}]},
            {Test.LoadRestrictions.Article, :read,
             [:id, :title, %{"author" => [:id, :name]}, %{"comments" => [:id, :body]}]}
          ] do
        live = FieldSelector.process(resource, action, fields, %{})

        assert {:ok, {_select, load, _template}} = live,
               "fixture assumption broken: #{inspect(resource)}.#{action} does not select"

        assert load != [],
               "#{inspect(resource)}.#{action} loads nothing, so the relationship path is untested"

        assert live == FieldSelector.process(resource, action, fields, ManifestFixture.config()),
               "field selection diverged for #{inspect(resource)}.#{action}"
      end
    end

    test "an unknown field is refused the same way either way" do
      for config <- [%{}, ManifestFixture.config()] do
        assert {:error, {:unknown_field, :nope, Test.User, []}} =
                 FieldSelector.process(Test.User, :read, [:nope], config)
      end
    end
  end

  describe "the manifest is genuinely in play" do
    test "the config the pipeline is handed carries a prepared source" do
      # Without this the parity assertions above would also hold for a config
      # key that reached nothing at all.
      assert %AshIntrospection.ResourceInfo.Source{} = ManifestFixture.config().manifest

      assert LedgerEntry in ManifestFixture.resource_modules(),
             "the fixture manifest does not carry LedgerEntry, so these tests read live twice"

      assert Account in ManifestFixture.resource_modules(),
             "the fixture manifest does not carry Account, so the identity test reads live twice"
    end
  end
end
