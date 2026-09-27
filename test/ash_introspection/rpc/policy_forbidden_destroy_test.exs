# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PolicyForbiddenDestroyTest do
  @moduledoc """
  Pins the wire shape a client gets back when a real `Ash.Policy.Authorizer`
  denial reaches it through `Pipeline.execute_ash_action/2`.

  Every other RPC test resource carries no policy, so this path was exercised
  only by hand-building an `Ash.Error.Forbidden.Policy` struct
  (`error_detail_leak_test.exs`), never by a genuine policy decision. A
  destroy carries the assertion rather than a read, because a read action
  filters unauthorized rows out (`authorize_with: :filter`) instead of
  returning `Forbidden`. `AshIntrospection.Test.Policy.Memo` reads are open to
  any actor and destroy is owner-only — see its `@moduledoc` and
  `AshIntrospection.Test.Policy.OwnerCheck`'s for why the reverse (an
  owner-scoped read, or a plain `expr/1` check on destroy) cannot produce a
  genuine `Forbidden` through this pipeline's actual bulk-destroy options.
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
