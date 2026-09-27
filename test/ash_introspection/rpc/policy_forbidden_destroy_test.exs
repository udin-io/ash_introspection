# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PolicyForbiddenDestroyTest do
  @moduledoc """
  Pins the wire shape a client gets back when a real `Ash.Policy.Authorizer`
  denial on a readable row reaches it through `Pipeline.execute_ash_action/2`.
  `AshIntrospection.Test.Policy.Memo` reads are open and destroy is
  owner-only, so Ash itself returns the `Forbidden.Policy`. A row the read
  policy hides is `policy_forbidden_write_test.exs`'s case.
  """
  use ExUnit.Case, async: false

  alias AshIntrospection.Rpc.ErrorBuilder
  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.ManifestFixture
  alias AshIntrospection.Test.Policy.Domain
  alias AshIntrospection.Test.Policy.Memo

  defp execute(request),
    do: Pipeline.execute_ash_action(request, ManifestFixture.decorated_config())

  setup do
    suffix = System.unique_integer([:positive])

    memo =
      Memo
      |> Ash.Changeset.for_create(:create, %{
        slug: "memo-#{suffix}",
        body: "owner-only body",
        owner_id: "owner-1"
      })
      |> Ash.create!()

    %{memo: memo}
  end

  test "a policy-denied destroy reaches the client as a forbidden error", %{memo: memo} do
    assert {:error, errors} = execute(destroy_request(memo.id, %{id: "someone-else"}))

    responses = ErrorBuilder.build_error_response(errors)

    assert [response] = responses
    assert response.type == "forbidden"
    assert response.short_message == "Forbidden"
  end

  test "the owner may destroy their own record", %{memo: memo} do
    assert {:ok, _record} = execute(destroy_request(memo.id, %{id: "owner-1"}))
  end

  defp destroy_request(id, actor) do
    Request.new(%{
      domain: Domain,
      resource: Memo,
      action: Ash.Resource.Info.action(Memo, :destroy),
      rpc_action: %{identities: [:_primary_key]},
      input: %{},
      context: %{},
      actor: actor,
      select: [:id, :owner_id],
      load: [],
      extraction_template: [:id, :owner_id],
      identity: id
    })
  end
end
