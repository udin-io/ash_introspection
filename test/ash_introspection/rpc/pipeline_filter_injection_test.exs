# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineFilterInjectionTest do
  @moduledoc """
  `get_by` values arrive from the client and are applied through
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
end
