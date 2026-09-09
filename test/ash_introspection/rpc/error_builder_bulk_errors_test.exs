# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.ErrorBuilderBulkErrorsTest do
  @moduledoc """
  Pins the error payload a client receives when a bulk action fails.

  `execute_update_action/3` and `execute_destroy_action/3` run through
  `Ash.bulk_update/4` and `Ash.bulk_destroy/4`, whose `%Ash.BulkResult{}`
  carries `errors:` as a LIST. A list is neither an exception nor a map, so it
  missed every clause in `build_error_response/1` and landed on the `other ->`
  catch-all: every per-record validation error collapsed into one
  "An unexpected error occurred" and the client learned nothing about which
  field was wrong.

  These tests drive a real `Ash.bulk_update` through the pipeline and assert
  each per-record error survives as its own response.
  """
  use ExUnit.Case, async: false

  alias AshIntrospection.Rpc.ErrorBuilder
  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.Account
  alias AshIntrospection.Test.RpcDomain

  setup do
    on_exit(fn -> Ash.DataLayer.Ets.stop(Account) end)

    suffix = System.unique_integer([:positive])

    account =
      Account
      |> Ash.Changeset.for_create(:create, %{
        name: "Bulk-#{suffix}",
        email: "bulk-#{suffix}@example.com",
        active: true
      })
      |> Ash.create!()

    %{account: account}
  end

  describe "a failing bulk update" do
    test "reaches the client as one error per failed field", %{account: account} do
      assert {:error, errors} = update(account.id, %{name: nil, email: nil})
      assert is_list(errors)

      responses = ErrorBuilder.build_error_response(errors)

      assert is_list(responses)
      assert length(responses) == 2
      assert Enum.all?(responses, &(&1.type == "required"))
      assert Enum.sort(Enum.flat_map(responses, & &1.fields)) == ["email", "name"]
    end

    test "never collapses into the unknown_error catch-all", %{account: account} do
      assert {:error, errors} = update(account.id, %{name: nil, email: nil})

      responses = ErrorBuilder.build_error_response(errors)

      refute Enum.any?(responses, &(&1.type == "unknown_error"))
      refute Enum.any?(responses, &(&1.message == "An unexpected error occurred"))
    end
  end

  describe "a list of errors" do
    test "flattens the sub-errors of each element" do
      errors = [
        Ash.Error.to_error_class(Ash.Error.Changes.Required.exception(field: :title)),
        Ash.Error.to_error_class(Ash.Error.Query.NotFound.exception())
      ]

      responses = ErrorBuilder.build_error_response(errors)

      assert length(responses) == 2
      assert Enum.map(responses, & &1.type) |> Enum.sort() == ["not_found", "required"]
    end

    test "an empty list produces no errors" do
      assert ErrorBuilder.build_error_response([]) == []
    end
  end

  defp update(id, input) do
    Pipeline.execute_ash_action(
      Request.new(%{
        domain: RpcDomain,
        resource: Account,
        action: Ash.Resource.Info.action(Account, :update),
        rpc_action: %{identities: [:_primary_key]},
        input: input,
        context: %{},
        select: [:id, :name, :email],
        load: [],
        extraction_template: [:id, :name, :email],
        identity: id
      })
    )
  end
end
