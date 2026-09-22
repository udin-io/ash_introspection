# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineManifestRequiredTest do
  @moduledoc """
  The four request entry points require a manifest, and arm the strict flag
  that makes a missed decoration raise.

  The entry points are `Pipeline.execute_ash_action/2`,
  `Pipeline.process_result/3`, `Pipeline.format_output_with_request/3` and
  `FieldProcessing.FieldSelector.process/4`. `Pipeline.format_output/2` is not
  one: it has no request, reads no resource and stays callable on a bare
  config.

  This is the break in 0.6.0. Before it, a config with no `:manifest` read live
  `Ash.Resource.Info` at every stage, which is what every consumer shipped.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.ManifestError
  alias AshIntrospection.Rpc.FieldProcessing.FieldSelector
  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.Account
  alias AshIntrospection.Test.LedgerEntry
  alias AshIntrospection.Test.ListOutputDomain
  alias AshIntrospection.Test.ManifestFixture
  alias AshIntrospection.Test.RpcDomain
  alias AshIntrospection.Test.User

  setup do
    LedgerEntry
    |> Ash.Changeset.for_create(:create, %{account_name: "alpha", entry_amount: 10})
    |> Ash.create!()

    :ok
  end

  defp request do
    Request.new(%{
      domain: ListOutputDomain,
      resource: LedgerEntry,
      action: Ash.Resource.Info.action(LedgerEntry, :list_entries),
      rpc_action: %{},
      input: %{},
      context: %{},
      select: [:id, :account_name, :entry_amount],
      load: [],
      extraction_template: [:id, :account_name, :entry_amount],
      show_metadata: []
    })
  end

  defp update_request do
    account =
      Account
      |> Ash.Changeset.for_create(:create, %{
        name: "Required-#{System.unique_integer([:positive])}",
        email: "required-#{System.unique_integer([:positive])}@example.com",
        active: true
      })
      |> Ash.create!()

    Request.new(%{
      domain: RpcDomain,
      resource: Account,
      action: Ash.Resource.Info.action(Account, :update),
      rpc_action: %{},
      input: %{email: "moved@example.com"},
      context: %{},
      select: [:id, :email],
      load: [],
      extraction_template: [:id, :email],
      identity: account.id
    })
  end

  defp ash_result do
    {:ok, result} = Pipeline.execute_ash_action(request(), ManifestFixture.decorated_config())
    result
  end

  describe "an empty config raises at every entry point" do
    test "execute_ash_action/2" do
      assert_raise ManifestError, ~r/requires a manifest/, fn ->
        Pipeline.execute_ash_action(request(), %{})
      end
    end

    test "process_result/3" do
      result = ash_result()

      assert_raise ManifestError, ~r/requires a manifest/, fn ->
        Pipeline.process_result(result, request(), %{})
      end
    end

    test "format_output_with_request/3" do
      assert_raise ManifestError, ~r/requires a manifest/, fn ->
        Pipeline.format_output_with_request(%{success: true, data: %{}}, request(), %{})
      end
    end

    test "FieldSelector.process/4" do
      assert_raise ManifestError, ~r/requires a manifest/, fn ->
        FieldSelector.process(User, :read, [:id, :name], %{})
      end
    end
  end

  describe "omitting the config argument raises the same way" do
    test "execute_ash_action/1" do
      assert_raise ManifestError, fn -> Pipeline.execute_ash_action(request()) end
    end

    test "process_result/2" do
      result = ash_result()

      assert_raise ManifestError, fn -> Pipeline.process_result(result, request()) end
    end

    test "format_output_with_request/2" do
      assert_raise ManifestError, fn ->
        Pipeline.format_output_with_request(%{success: true, data: %{}}, request())
      end
    end

    test "FieldSelector.process/3" do
      assert_raise ManifestError, fn -> FieldSelector.process(User, :read, [:id, :name]) end
    end
  end

  describe "a manifest that carries the resource undecorated raises" do
    # Stage 2 reads the decoration through `authorize_bulk_strategy/2`, which
    # every update and destroy goes through. A plain read reads no decorated
    # data in stage 2 at all — see the test below this describe block.
    test "execute_ash_action/2, on an update" do
      assert_raise ManifestError, ~r/did not decorate/, fn ->
        Pipeline.execute_ash_action(update_request(), ManifestFixture.config())
      end
    end

    test "process_result/3" do
      result = ash_result()

      assert_raise ManifestError, ~r/did not decorate/, fn ->
        Pipeline.process_result(result, request(), ManifestFixture.config())
      end
    end

    test "format_output_with_request/3" do
      {:ok, processed} =
        Pipeline.process_result(ash_result(), request(), ManifestFixture.decorated_config())

      assert_raise ManifestError, ~r/did not decorate/, fn ->
        Pipeline.format_output_with_request(
          %{success: true, data: processed},
          request(),
          ManifestFixture.config()
        )
      end
    end

    test "FieldSelector.process/4" do
      assert_raise ManifestError, ~r/did not decorate/, fn ->
        FieldSelector.process(User, :read, [:id, :name], ManifestFixture.config())
      end
    end
  end

  describe "where the raise lands" do
    test "a plain read passes stage 2 undecorated and raises in stage 3" do
      # The raise comes from the reader, not from the entry point: stage 2 of a
      # read with no `get_by` and no identity asks the manifest nothing. The
      # request still cannot complete — stage 3 types every extracted field.
      assert {:ok, result} = Pipeline.execute_ash_action(request(), ManifestFixture.config())

      assert_raise ManifestError, ~r/did not decorate/, fn ->
        Pipeline.process_result(result, request(), ManifestFixture.config())
      end
    end
  end

  describe "a decorated manifest runs the whole request" do
    test "the four stages together" do
      config = ManifestFixture.decorated_config()
      request = request()

      assert {:ok, {select, _load, template}} =
               FieldSelector.process(LedgerEntry, :list_entries, [:id, :account_name], config)

      assert select != []
      assert template != []

      assert {:ok, result} = Pipeline.execute_ash_action(request, config)
      assert {:ok, processed} = Pipeline.process_result(result, request, config)

      response =
        Pipeline.format_output_with_request(%{success: true, data: processed}, request, config)

      assert %{"success" => true, "data" => [%{"accountName" => "alpha"} | _]} = response
    end

    test "the config the caller passed is not mutated" do
      config = ManifestFixture.decorated_config()

      refute config.manifest.strict?
      assert {:ok, _} = Pipeline.execute_ash_action(request(), config)
      refute config.manifest.strict?
    end
  end

  describe "format_output/2 is not an entry point" do
    test "it still formats on a bare config" do
      assert %{"accountName" => "alpha"} = Pipeline.format_output(%{account_name: "alpha"}, %{})
    end
  end
end
