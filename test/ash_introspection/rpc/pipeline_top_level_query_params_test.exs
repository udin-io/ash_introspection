# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineTopLevelQueryParamsTest do
  @moduledoc """
  A top-level `filter`, `sort` or `page` the action cannot use is refused
  (#24). Before #24 a `get?` read, a create, an update, a destroy and a generic
  action each ignored them and succeeded, so the client could not tell an
  unfiltered answer from a filtered one.

  Each refusal goes through `ErrorBuilder` and `Jason`, so the test asserts the
  error the client reads.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Rpc.ErrorBuilder
  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.Account
  alias AshIntrospection.Test.Ledger
  alias AshIntrospection.Test.LedgerEntry
  alias AshIntrospection.Test.ManifestFixture

  setup do
    alice = create_account!("Alice")
    bob = create_account!("Bob")
    %{alice: alice, bob: bob}
  end

  describe "a get? read" do
    test "refuses filter instead of returning the record", %{alice: alice} do
      assert {:error,
              %{"type" => "filter_not_supported", "details" => %{"reason" => "unsupported"}}} =
               run(Account, :get_account, %{
                 get_by: %{id: alice.id},
                 filter: %{"name" => %{"eq" => "Bob"}}
               })
    end

    test "refuses filter with no get_by as well" do
      assert {:error, %{"type" => "filter_not_supported"}} =
               run(Account, :get_account, %{filter: %{"name" => %{"eq" => "Bob"}}})
    end

    test "refuses sort", %{alice: alice} do
      assert {:error,
              %{"type" => "sort_not_supported", "details" => %{"reason" => "unsupported"}}} =
               run(Account, :get_account, %{get_by: %{id: alice.id}, sort: "name"})
    end

    test "refuses page, an empty page included", %{alice: alice} do
      for page <- [%{limit: 1}, %{}] do
        assert {:error, %{"type" => "pagination_not_supported"}} =
                 run(Account, :get_account, %{get_by: %{id: alice.id}, pagination: page})
      end
    end

    test "with none of the three still returns the record", %{alice: alice} do
      assert {:ok, %{name: "Alice"}} = run(Account, :get_account, %{get_by: %{id: alice.id}})
    end
  end

  describe "a mutation or a generic action" do
    test "create refuses filter and writes nothing" do
      assert {:error, %{"type" => "filter_not_supported"}} =
               run(Account, :create, %{
                 input: %{name: "Carol", email: "carol@example.com"},
                 filter: %{"name" => %{"eq" => "Carol"}}
               })

      refute Enum.any?(Ash.read!(Account), &(&1.name == "Carol"))
    end

    test "update refuses filter and writes nothing", %{alice: alice} do
      assert {:error, %{"type" => "filter_not_supported"}} =
               run(Account, :update, %{
                 identity: alice.id,
                 input: %{name: "Changed"},
                 filter: %{"name" => %{"eq" => "Alice"}}
               })

      assert Ash.get!(Account, alice.id).name == "Alice"
    end

    test "destroy refuses filter and deletes nothing", %{alice: alice} do
      assert {:error, %{"type" => "filter_not_supported"}} =
               run(Account, :destroy, %{
                 identity: alice.id,
                 filter: %{"name" => %{"eq" => "Alice"}}
               })

      assert Ash.get!(Account, alice.id)
    end

    test "a generic action refuses filter" do
      assert {:error, %{"type" => "filter_not_supported"}} =
               run(Ledger, :ping, %{filter: %{"name" => %{"eq" => "x"}}})
    end

    test "create and a generic action with none of the three still succeed" do
      assert {:ok, %{name: "Carol"}} =
               run(Account, :create, %{input: %{name: "Carol", email: "carol@example.com"}})

      assert {:ok, true} = run(Ledger, :ping, %{select: [], extraction_template: []})
    end
  end

  describe "a list read" do
    test "refuses filter when the RPC action disables filtering" do
      assert {:error, %{"type" => "filter_not_supported", "details" => %{"reason" => "disabled"}}} =
               run(Account, :read, %{
                 rpc_action: %{enable_filter?: false},
                 filter: %{"name" => %{"eq" => "Bob"}}
               })
    end

    test "refuses sort when the RPC action disables sorting" do
      assert {:error, %{"type" => "sort_not_supported", "details" => %{"reason" => "disabled"}}} =
               run(Account, :read, %{rpc_action: %{enable_sort?: false}, sort: "name"})
    end

    test "refuses page on an action that does not paginate" do
      assert {:error, %{"type" => "pagination_not_supported"}} =
               run(LedgerEntry, :list_entries, %{
                 pagination: %{limit: 1},
                 select: [:id],
                 extraction_template: [:id]
               })
    end

    test "refuses filter on a get_by lookup", %{alice: alice} do
      assert {:error, %{"type" => "filter_not_supported"}} =
               run(Account, :read, %{
                 get_by: %{id: alice.id},
                 filter: %{"name" => %{"eq" => "Bob"}}
               })
    end

    test "refuses filter when the RPC action is a get or declares get_by" do
      for rpc_action <- [%{get?: true}, %{get_by: [:email]}] do
        assert {:error, %{"type" => "filter_not_supported"}} =
                 run(Account, :read, %{
                   rpc_action: rpc_action,
                   filter: %{"name" => %{"eq" => "Bob"}}
                 })
      end
    end

    test "still filters" do
      assert {:ok, [%{name: "Bob"}]} =
               run(Account, :read, %{filter: %{"name" => %{"eq" => "Bob"}}})
    end

    test "still pages" do
      assert {:ok, %{results: [_], has_more: true}} =
               run(Account, :read, %{sort: "name", pagination: %{limit: 1}})
    end
  end

  defp run(resource, action, attrs) do
    config = ManifestFixture.decorated_config()

    request =
      Request.new(
        Map.merge(
          %{
            domain: Ash.Resource.Info.domain(resource),
            resource: resource,
            action: Ash.Resource.Info.action(resource, action),
            rpc_action: %{},
            input: %{},
            context: %{},
            select: [:id, :name],
            load: [],
            extraction_template: [:id, :name]
          },
          attrs
        )
      )

    case Pipeline.execute_ash_action(request, config) do
      {:ok, result} ->
        Pipeline.process_result(result, request, config)

      {:error, error} when is_tuple(error) ->
        {:error,
         error |> ErrorBuilder.build_error_response() |> Jason.encode!() |> Jason.decode!()}

      other ->
        other
    end
  end

  defp create_account!(name) do
    Account
    |> Ash.Changeset.for_create(:create, %{
      name: name,
      email: "#{String.downcase(name)}-#{System.unique_integer([:positive])}@example.com"
    })
    |> Ash.create!()
  end
end
