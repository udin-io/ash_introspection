# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource AshIntrospection.Test.User
    resource AshIntrospection.Test.Address
  end
end

defmodule AshIntrospection.Test.User do
  @moduledoc false
  use Ash.Resource, domain: AshIntrospection.Test.Domain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :email, :string, public?: true
    attribute :age, :integer, public?: true
    attribute :is_active, :boolean, default: true, public?: true
    attribute :metadata, :map, public?: true
  end

  relationships do
    has_one :address, AshIntrospection.Test.Address, public?: true
  end

  calculations do
    calculate :full_name, :string, expr(name)
  end

  aggregates do
    count :address_count, :address, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshIntrospection.Test.Address do
  @moduledoc false
  use Ash.Resource,
    domain: AshIntrospection.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :street, :string, public?: true
    attribute :city, :string, public?: true
    attribute :country, :string, public?: true
    attribute :user_id, :uuid, public?: true
  end

  relationships do
    belongs_to :user, AshIntrospection.Test.User
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshIntrospection.Test.EmbeddedAddress do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :street, :string, public?: true
    attribute :city, :string, public?: true
    attribute :zip_code, :string, public?: true
  end
end

defmodule AshIntrospection.Test.TaskStats do
  @moduledoc """
  A NewType with interop_field_names for testing.
  """
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        is_active?: [type: :boolean],
        task_count: [type: :integer],
        meta_1: [type: :string]
      ]
    ]

  @doc """
  Returns field name mappings for interop (TypeScript, Kotlin, etc.).
  """
  def interop_field_names do
    [
      is_active?: "isActive",
      task_count: "taskCount",
      meta_1: "meta1"
    ]
  end
end

defmodule AshIntrospection.Test.CustomType do
  @moduledoc """
  A custom type with interop_type_name callback.
  """
  use Ash.Type

  @impl Ash.Type
  def storage_type, do: :string

  @impl Ash.Type
  def cast_input(value, _), do: {:ok, to_string(value)}

  @impl Ash.Type
  def cast_stored(nil, _), do: {:ok, nil}
  def cast_stored(value, _), do: {:ok, value}

  @impl Ash.Type
  def dump_to_native(nil, _), do: {:ok, nil}
  def dump_to_native(value, _), do: {:ok, value}

  def interop_type_name, do: "CustomString"
end

# ─────────────────────────────────────────────────────────────────
# Test Resources for Action Introspection
# ─────────────────────────────────────────────────────────────────

defmodule AshIntrospection.Test.ActionDomain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource AshIntrospection.Test.Post
  end
end

defmodule AshIntrospection.Test.Post do
  @moduledoc """
  A resource with various action configurations for testing action introspection.
  """
  use Ash.Resource,
    domain: AshIntrospection.Test.ActionDomain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :body, :string, public?: true
    attribute :published, :boolean, default: false, public?: true
    attribute :view_count, :integer, default: 0, public?: true
  end

  actions do
    # Basic read with no pagination
    read :read do
      primary? true
    end

    # Read with offset pagination
    read :list_offset do
      pagination offset?: true, default_limit: 10, max_page_size: 100, countable: true
    end

    # Read with keyset pagination
    read :list_keyset do
      pagination keyset?: true, default_limit: 20
    end

    # Read with required pagination
    read :list_required do
      pagination offset?: true, required?: true, default_limit: 25
    end

    # Read with both pagination types
    read :list_hybrid do
      pagination offset?: true, keyset?: true, default_limit: 15
    end

    # Get action (not paginated)
    read :get_by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
    end

    # Create with required input
    create :create do
      accept [:title, :body, :published]
    end

    # Create with optional input
    create :create_draft do
      accept [:title, :body]
      argument :tags, {:array, :string}, public?: true
    end

    # Update with optional input
    update :update do
      accept [:title, :body, :published]
    end

    # Destroy action
    destroy :destroy

    # Generic action returning a resource
    action :get_featured, :struct do
      constraints instance_of: AshIntrospection.Test.Post

      run fn _input, _context ->
        {:ok, nil}
      end
    end

    # Generic action returning array of resources
    action :get_popular, {:array, :struct} do
      constraints items: [instance_of: AshIntrospection.Test.Post]
      argument :limit, :integer, default: 10, public?: true

      run fn _input, _context ->
        {:ok, []}
      end
    end

    # Generic action returning typed map
    action :get_stats, :map do
      constraints fields: [
                    total_posts: [type: :integer],
                    published_count: [type: :integer],
                    draft_count: [type: :integer]
                  ]

      run fn _input, _context ->
        {:ok, %{total_posts: 0, published_count: 0, draft_count: 0}}
      end
    end

    # Generic action returning unconstrained map
    action :get_metadata, :map do
      run fn _input, _context ->
        {:ok, %{}}
      end
    end

    # Generic action returning primitive (not field selectable)
    action :get_count, :integer do
      run fn _input, _context ->
        {:ok, 0}
      end
    end

    # Generic action with no input
    action :ping, :boolean do
      run fn _input, _context ->
        {:ok, true}
      end
    end

    # Generic action with required input
    action :search, {:array, :struct} do
      constraints items: [instance_of: AshIntrospection.Test.Post]
      argument :query, :string, allow_nil?: false, public?: true
      argument :limit, :integer, default: 10, public?: true

      run fn _input, _context ->
        {:ok, []}
      end
    end
  end
end
