# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineIdentityBooleanTest do
  @moduledoc """
  Pins named-identity lookups against a `false` identity value collapsing to
  `nil`.

  `build_named_identity_filter/2` read each key with
  `Map.get(identity, key) || Map.get(identity, to_string(key))`. `false` is
  falsy, so the `||` discarded it and the filter became `active == nil` — a
  predicate the caller never asked for, which resolves to the wrong record or
  to none at all. Identities drive `execute_update_action/3`
  and `execute_destroy_action/3` (reads use `get_by`), so these tests exercise
  those two against three accounts that differ only in `:active` — `false`,
  `true` and `nil` — and assert which record changed and which did not.

  Since #44 a genuinely `nil` identity value is rejected rather than compiled
  to `active == nil`, so the `false`/`nil` distinction is now enforced from
  both sides.
  """
  use ExUnit.Case, async: false

  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.Account
  alias AshIntrospection.Test.RpcDomain

  setup do
    suffix = System.unique_integer([:positive])
    name = "Shared-#{suffix}"

    accounts =
      Map.new([{:inactive, false}, {:active, true}, {:unset, nil}], fn {label, active} ->
        account =
          Account
          |> Ash.Changeset.for_create(:create, %{
            name: name,
            email: "#{label}-#{suffix}@example.com",
            active: active
          })
          |> Ash.create!()

        {label, account}
      end)

    Map.put(accounts, :name, name)
  end

  defp update_request(identity, input) do
    Request.new(%{
      domain: RpcDomain,
      resource: Account,
      action: Ash.Resource.Info.action(Account, :update),
      rpc_action: %{identities: [:unique_name_active]},
      input: input,
      context: %{},
      select: [:id, :name, :email, :active],
      load: [],
      extraction_template: [:id, :name, :email, :active],
      identity: identity
    })
  end

  defp destroy_request(identity) do
    Request.new(%{
      domain: RpcDomain,
      resource: Account,
      action: Ash.Resource.Info.action(Account, :destroy),
      rpc_action: %{identities: [:unique_name_active]},
      input: %{},
      context: %{},
      select: [:id, :name, :email, :active],
      load: [],
      extraction_template: [:id, :name, :email, :active],
      identity: identity
    })
  end

  defp emails(ctx) do
    Map.new([:inactive, :active, :unset], fn label ->
      {label, Ash.get!(Account, Map.fetch!(ctx, label).id).email}
    end)
  end

  describe "updates through a boolean named identity" do
    test "an identity value of false updates the false record and nothing else",
         %{name: name} = ctx do
      assert {:ok, record} =
               Pipeline.execute_ash_action(
                 update_request(%{name: name, active: false}, %{email: "renamed@example.com"})
               )

      assert record.id == ctx.inactive.id

      assert %{inactive: "renamed@example.com", active: ctx.active.email, unset: ctx.unset.email} ==
               emails(ctx)
    end

    test "an identity value of true updates the true record and nothing else",
         %{name: name} = ctx do
      assert {:ok, record} =
               Pipeline.execute_ash_action(
                 update_request(%{name: name, active: true}, %{email: "renamed@example.com"})
               )

      assert record.id == ctx.active.id

      assert %{
               inactive: ctx.inactive.email,
               active: "renamed@example.com",
               unset: ctx.unset.email
             } ==
               emails(ctx)
    end

    test "an identity value of nil is rejected and changes nothing", %{name: name} = ctx do
      # `false` and `nil` must not be interchangeable. Until #44 a nil value
      # compiled to `active == nil`, which Ash evaluates as unknown, so the
      # update failed as `NotFound` — an answer that reads as "no such record"
      # when the real fault is an identity that cannot name one.
      assert {:error, {:invalid_identity, %{message: message}}} =
               Pipeline.execute_ash_action(
                 update_request(%{name: name, active: nil}, %{email: "renamed@example.com"})
               )

      assert message =~ "null"
      assert message =~ "active"

      assert %{inactive: ctx.inactive.email, active: ctx.active.email, unset: ctx.unset.email} ==
               emails(ctx)
    end

    test "a nil identity value is rejected on destroy too and destroys nothing",
         %{name: name} = ctx do
      assert {:error, {:invalid_identity, %{message: _}}} =
               Pipeline.execute_ash_action(destroy_request(%{name: name, active: nil}))

      assert Ash.get!(Account, ctx.inactive.id)
      assert Ash.get!(Account, ctx.active.id)
      assert Ash.get!(Account, ctx.unset.id)
    end
  end

  describe "destroys through a boolean named identity" do
    test "an identity value of false destroys the false record and nothing else",
         %{name: name} = ctx do
      assert {:ok, _} = Pipeline.execute_ash_action(destroy_request(%{name: name, active: false}))

      assert {:error, _} = Ash.get(Account, ctx.inactive.id)
      assert Ash.get!(Account, ctx.active.id)
      assert Ash.get!(Account, ctx.unset.id)
    end
  end
end
