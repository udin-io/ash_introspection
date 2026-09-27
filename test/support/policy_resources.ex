# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.Policy.OwnerCheck do
  @moduledoc """
  Denies a destroy unless the loaded record belongs to the actor.

  A `SimpleCheck` has no filter form (`type: :simple`), so Ash reads the row
  and then evaluates the check against the changeset. The denial comes back
  from `Ash.bulk_destroy/4` as a real `Ash.Error.Forbidden.Policy`, with its
  policies attached. `Test.Policy.Note` covers the other shape: an `expr/1`
  policy that filters the row out of the lookup, which `Rpc.Pipeline` answers
  with its own existence check (#107).
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
  Read is open to any actor; destroy is owner-only through
  `AshIntrospection.Test.Policy.OwnerCheck`. The row stays visible, so a
  denied destroy is Ash's own `Forbidden.Policy`, not the pipeline's
  zero-row check.
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
  notes, for a write through `read_action`. `:rename_live` and `:purge_live`
  skip archived notes with a change-level filter, which the read does not see.
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

    update :rename_live do
      accept([:title])
      change(filter(expr(archived == false)))
    end

    destroy :purge_live do
      change(filter(expr(archived == false)))
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
