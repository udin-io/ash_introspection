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

  `:embedding` is an `Ash.Type.Vector`, whose `%Ash.Vector{}` keeps its floats
  in a packed binary that JSON cannot encode. It is here so the output path can
  be driven end to end against a real vector attribute.

  This is the only test resource anything writes to, and five test files write
  to it. `private? true` gives each *test process* its own unnamed ETS table
  (`Ash.DataLayer.Ets.wrap_or_create_table/3` keys it off the process
  dictionary, `deps/ash/lib/ash/data_layer/ets/ets.ex:2257`), which the VM
  reaps when the process exits. Without it there is one named table for the
  whole VM, guarded by a `TableManager` GenServer, and the only way to empty it
  between tests is `Ash.DataLayer.Ets.stop/1` — which kills that GenServer
  asynchronously and lets the next test wrap a table that is already doomed.
  See #55.
  """
  use Ash.Resource,
    domain: AshIntrospection.Test.RpcDomain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:email, :string, allow_nil?: false, public?: true)
    attribute(:active, :boolean, public?: true)
    attribute(:embedding, :vector, public?: true, constraints: [dimensions: 3])
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
