# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.RpcDomain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(AshIntrospection.Test.Account)
  end
end

defmodule AshIntrospection.Test.Account do
  @moduledoc """
  Resource for exercising the RPC pipeline's identity and `get_by` lookups.

  Carries a named identity (`:unique_email`) plus a `get?` read action so the
  pipeline's two trusted-filter paths — `maybe_apply_identity_filter/5` and
  `apply_get_by_filter/3` — can both be driven end to end.

  `:active` is a boolean identity key (`:unique_name_active`) because an
  identity value of `false` is the case a `Map.get/2 || Map.get/2` lookup
  silently turns into `nil`, resolving the filter against the wrong record.
  """
  use Ash.Resource,
    domain: AshIntrospection.Test.RpcDomain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:email, :string, allow_nil?: false, public?: true)
    attribute(:active, :boolean, public?: true)
  end

  identities do
    identity(:unique_email, [:email], pre_check_with: AshIntrospection.Test.RpcDomain)

    identity(:unique_name_active, [:name, :active],
      pre_check_with: AshIntrospection.Test.RpcDomain
    )
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    read :get_account do
      get?(true)
    end
  end
end
