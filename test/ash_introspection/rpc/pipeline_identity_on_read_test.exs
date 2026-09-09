# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineIdentityOnReadTest do
  @moduledoc """
  `identity` is an update/destroy lookup key. Read actions look records up with
  `get_by`, and until #44 a read carrying `identity` had it silently dropped:
  the client asked for one record and got the whole table back, or a
  `MultipleResults` error from `Ash.read_one/1` that named nothing useful.

  These tests pin the rejection — a read with `identity` fails with
  `:identity_not_supported` — and prove `get_by` still resolves the same lookup.
  """
  use ExUnit.Case, async: false

  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.Account
  alias AshIntrospection.Test.RpcDomain

  setup do
    suffix = System.unique_integer([:positive])

    alice =
      Account
      |> Ash.Changeset.for_create(:create, %{name: "Alice", email: "alice-#{suffix}@example.com"})
      |> Ash.create!()

    bob =
      Account
      |> Ash.Changeset.for_create(:create, %{name: "Bob", email: "bob-#{suffix}@example.com"})
      |> Ash.create!()

    %{alice: alice, bob: bob}
  end

  defp request(action, attrs) do
    Request.new(
      Map.merge(
        %{
          domain: RpcDomain,
          resource: Account,
          action: Ash.Resource.Info.action(Account, action),
          rpc_action: %{},
          input: %{},
          context: %{},
          select: [:id, :name, :email],
          load: [],
          extraction_template: [:id, :name, :email]
        },
        attrs
      )
    )
  end

  describe "identity on a read action" do
    test "a get? read carrying an identity is rejected by name", %{alice: alice} do
      assert {:error, {:identity_not_supported, %{action: :get_account}}} =
               Pipeline.execute_ash_action(request(:get_account, %{identity: alice.id}))
    end

    test "a list read carrying an identity is rejected", %{alice: alice} do
      assert {:error, {:identity_not_supported, %{action: :read}}} =
               Pipeline.execute_ash_action(request(:read, %{identity: alice.id}))
    end

    test "a map identity is rejected on a read", %{alice: alice} do
      assert {:error, {:identity_not_supported, _}} =
               Pipeline.execute_ash_action(
                 request(:get_account, %{identity: %{email: alice.email}})
               )
    end

    test "a read without an identity is untouched", %{alice: alice} do
      assert {:ok, record} =
               Pipeline.execute_ash_action(request(:get_account, %{get_by: %{id: alice.id}}))

      assert record.id == alice.id
    end

    test "a list read without an identity still returns every record", %{
      alice: alice,
      bob: bob
    } do
      assert {:ok, records} = Pipeline.execute_ash_action(request(:read, %{}))

      ids = MapSet.new(records, & &1.id)
      assert MapSet.member?(ids, alice.id)
      assert MapSet.member?(ids, bob.id)
    end
  end
end
