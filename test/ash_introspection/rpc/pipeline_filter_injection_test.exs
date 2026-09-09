# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineFilterInjectionTest do
  @moduledoc """
  Identity and `get_by` values arrive from the client and are applied through
  `Ash.Query.do_filter/2`, the *trusted* filter API. A map or list operand is
  read there as an operator expression rather than an equality match, so an
  exact-record lookup becomes an arbitrary predicate. These tests pin the
  rejection and prove the legitimate scalar lookups still work.
  """
  use ExUnit.Case, async: false

  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.Account
  alias AshIntrospection.Test.RpcDomain

  setup do
    on_exit(fn -> Ash.DataLayer.Ets.stop(Account) end)

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

  defp get_request(get_by) do
    Request.new(%{
      domain: RpcDomain,
      resource: Account,
      action: Ash.Resource.Info.action(Account, :get_account),
      rpc_action: %{},
      input: %{},
      context: %{},
      select: [:id, :name, :email],
      load: [],
      extraction_template: [:id, :name, :email],
      get_by: get_by
    })
  end

  defp update_request(identity, identities, input) do
    Request.new(%{
      domain: RpcDomain,
      resource: Account,
      action: Ash.Resource.Info.action(Account, :update),
      rpc_action: %{identities: identities},
      input: input,
      context: %{},
      select: [:id, :name, :email],
      load: [],
      extraction_template: [:id, :name, :email],
      identity: identity
    })
  end

  defp destroy_request(identity, identities) do
    Request.new(%{
      domain: RpcDomain,
      resource: Account,
      action: Ash.Resource.Info.action(Account, :destroy),
      rpc_action: %{identities: identities},
      input: %{},
      context: %{},
      select: [:id, :name, :email],
      load: [],
      extraction_template: [:id, :name, :email],
      identity: identity
    })
  end

  describe "get_by lookups" do
    test "an exact scalar value still resolves the named record", %{alice: alice} do
      assert {:ok, record} = Pipeline.execute_ash_action(get_request(%{email: alice.email}))
      assert record.id == alice.id
    end

    test "rejects an operator map instead of matching a record the caller never named" do
      # Without validation this compiles to `email < "zzz"` and returns whichever
      # account the data layer reads first.
      assert {:error, {:invalid_get_by, %{message: message}}} =
               Pipeline.execute_ash_action(get_request(%{email: %{"less_than" => "zzz"}}))

      assert message =~ "email"
    end

    test "rejects a list value", %{alice: alice, bob: bob} do
      assert {:error, {:invalid_get_by, _}} =
               Pipeline.execute_ash_action(get_request(%{email: [alice.email, bob.email]}))
    end

    test "names every non-scalar field in the error message" do
      assert {:error, {:invalid_get_by, %{message: message}}} =
               Pipeline.execute_ash_action(
                 get_request(%{email: %{"less_than" => "zzz"}, name: ["Alice"]})
               )

      assert message =~ "email"
      assert message =~ "name"
    end
  end

  describe "identity lookups on update" do
    test "an exact scalar identity still updates the named record", %{alice: alice, bob: bob} do
      assert {:ok, record} =
               Pipeline.execute_ash_action(
                 update_request(%{email: alice.email}, [:unique_email], %{name: "Alice Renamed"})
               )

      assert record.id == alice.id
      assert Ash.get!(Account, bob.id).name == "Bob"
    end

    test "rejects an operator map as a named identity value and leaves records untouched", %{
      alice: alice,
      bob: bob
    } do
      # Without validation this compiles to `email > ""` and the bulk update
      # renames whichever account the data layer reads first.
      assert {:error, {:invalid_identity, %{message: message}}} =
               Pipeline.execute_ash_action(
                 update_request(%{email: %{"greater_than" => ""}}, [:unique_email], %{
                   name: "Injected"
                 })
               )

      assert message =~ "email"
      assert Ash.get!(Account, alice.id).name == "Alice"
      assert Ash.get!(Account, bob.id).name == "Bob"
    end

    test "rejects a non-scalar primary key identity value", %{alice: alice} do
      assert {:error, {:invalid_identity, _}} =
               Pipeline.execute_ash_action(
                 update_request([alice.id], [:_primary_key], %{name: "Injected PK"})
               )

      assert Ash.get!(Account, alice.id).name == "Alice"
    end
  end

  describe "identity lookups on destroy" do
    test "rejects an operator map as a named identity value and destroys nothing", %{
      alice: alice,
      bob: bob
    } do
      assert {:error, {:invalid_identity, _}} =
               Pipeline.execute_ash_action(
                 destroy_request(%{email: %{"greater_than" => ""}}, [:unique_email])
               )

      assert Ash.get!(Account, alice.id)
      assert Ash.get!(Account, bob.id)
    end

    test "an exact scalar identity still destroys the named record", %{alice: alice, bob: bob} do
      assert {:ok, _} =
               Pipeline.execute_ash_action(
                 destroy_request(%{email: alice.email}, [:unique_email])
               )

      assert {:error, _} = Ash.get(Account, alice.id)
      assert Ash.get!(Account, bob.id)
    end
  end
end
