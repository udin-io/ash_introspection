# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.Policy.OwnerCheck do
  @moduledoc """
  Denies a destroy the query stage cannot silently filter away.

  `Pipeline.execute_destroy_action/3` runs every destroy through
  `Ash.bulk_destroy/4` with `authorize_changeset_with:` set, but no
  `authorize_with:`/`authorize_query_with:` — so the query half of the bulk
  operation keeps Ash's own default, `filter_with: :filter`
  (`deps/ash/lib/ash/actions/destroy/bulk.ex:1370`). A plain
  `expr(owner_id == ^actor(:id))` check on the destroy policy is trivially
  filterable, so the bulk operation's own internal read (fetching the row to
  destroy) silently drops a row the actor does not own *before* any
  destroy-specific check runs — the destroy reaches the client as
  `{:ok, %{}}` (zero rows destroyed), never `{:error, _}`.

  `Memo`'s read policy is left open (`always()`) for this reason: it is the
  read step's authorization the query stage actually applies, so the read
  policy is what decides whether the row is visible to fetch at all. Making
  read owner-scoped too would just move the silent-filter problem into
  `execute_destroy_action/3`'s own row lookup, the same "cannot tell
  not-found from forbidden" outcome the read path already has and this
  fixture exists to avoid for a *write*.

  A `SimpleCheck` has no filter form at all (`type: :simple`,
  `deps/ash/lib/ash/policy/simple_check.ex`), so Ash cannot push it into the
  query, reads the (visible) row, and evaluates this check against the
  loaded changeset — which is what finally produces a genuine
  `Ash.Error.Forbidden.Policy`.

  Forcing the *expr* check through the error path instead
  (`authorize_with: :error` passed straight to `Ash.bulk_destroy/4`) was
  tried and dropped: on `Ash.DataLayer.Ets`, Ash's compiled `:atomic` match
  spec embeds the authorizer as a string rather than the module atom, and
  raises `** (ArgumentError) ... :erlang.function_exported("Ash.Policy.Authorizer", ...)`
  from `deps/ash/lib/ash/actions/destroy/bulk.ex:805` — the library's own
  "please report a bug" placeholder error. Reproduced 2026-09-27 on ash
  3.33.4 against `Ash.DataLayer.Ets`; not filed upstream by this ticket,
  which only needed a check shape that avoids it.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "record belongs to the actor"

  @impl true
  def requires_original_data?(_authorizer, _opts), do: true

  @impl true
  def match?(actor, %{subject: %Ash.Changeset{data: %{owner_id: owner_id}}}, _opts) do
    {:ok, owner_id == actor_id(actor)}
  end

  def match?(_actor, _context, _opts), do: {:ok, false}

  defp actor_id(%{id: id}), do: id
  defp actor_id(_), do: nil
end

defmodule AshIntrospection.Test.Policy.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(AshIntrospection.Test.Policy.Memo)
    resource(AshIntrospection.Test.Policy.Note)
    resource(AshIntrospection.Test.Policy.TenantNote)
  end
end

defmodule AshIntrospection.Test.Policy.Memo do
  @moduledoc """
  The only test resource here that carries a real `Ash.Policy.Authorizer`.

  Every other RPC test resource is unauthorized, so the "forbidden" branch of
  the error pipeline (`error.ex`, `errors.ex`, `error_builder.ex`) was
  exercised only by hand-building an `Ash.Error.Forbidden.Policy` struct
  (`error_detail_leak_test.exs`), never by a real policy denial running
  through `Pipeline.execute_ash_action/2`. This resource closes that gap.

  Read is open to any actor and destroy is owner-only
  (`AshIntrospection.Test.Policy.OwnerCheck`), not the reverse. See that
  module's `@moduledoc` for why a plain `expr/1` check on destroy — or an
  owner-scoped read — cannot produce a genuine `Forbidden` through this
  pipeline's actual bulk-destroy options, only a silent zero-row success.
  """
  use Ash.Resource,
    domain: AshIntrospection.Test.Policy.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:slug, :string, allow_nil?: false, public?: true)
    attribute(:body, :string, allow_nil?: false, public?: true)
    attribute(:owner_id, :string, allow_nil?: false, public?: true)
  end

  identities do
    identity(:unique_slug, [:slug], pre_check_with: AshIntrospection.Test.Policy.Domain)
  end

  policies do
    policy action_type([:create, :update, :read]) do
      authorize_if(always())
    end

    policy action_type(:destroy) do
      authorize_if(AshIntrospection.Test.Policy.OwnerCheck)
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshIntrospection.Test.Policy.Note do
  @moduledoc """
  An owner-scoped record: an actor reads, updates and destroys only its own
  notes, through one `expr/1` policy. A read filters another owner's note out,
  so an update or destroy of it changes zero rows. `:active` hides archived
  notes, for a write through `read_action`.
  """
  use Ash.Resource,
    domain: AshIntrospection.Test.Policy.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, allow_nil?: false, public?: true)
    attribute(:owner_id, :string, allow_nil?: false, public?: true)
    attribute(:archived, :boolean, allow_nil?: false, default: false, public?: true)
  end

  policies do
    policy action_type(:create) do
      authorize_if(always())
    end

    policy action_type([:read, :update, :destroy]) do
      authorize_if(expr(owner_id == ^actor(:id)))
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    read :active do
      filter(expr(archived == false))
    end
  end
end

defmodule AshIntrospection.Test.Policy.TenantNote do
  @moduledoc """
  A note under attribute multitenancy. `global?` lets a query without a tenant
  see every tenant's rows, so a lookup that drops the tenant finds a row it
  should not.
  """
  use Ash.Resource,
    domain: AshIntrospection.Test.Policy.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(true)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:org_id)
    global?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, allow_nil?: false, public?: true)
    attribute(:org_id, :string, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end
