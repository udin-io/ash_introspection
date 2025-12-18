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
