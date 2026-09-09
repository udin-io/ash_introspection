# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.LoadRestrictions.Meta do
  @moduledoc """
  An embedded resource with a calculation of its own, so a field selection on
  it produces a non-empty nested load. That is the shape the embedded branch of
  `FieldSelector` appends to the load statement, and the one a restriction on
  the parent attribute has to cover.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :label, :string, public?: true
  end

  calculations do
    calculate :shout, :string, expr(label), public?: true
  end
end

defmodule AshIntrospection.Test.LoadRestrictions.ComputedMeta do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn _ -> %AshIntrospection.Test.LoadRestrictions.Meta{label: "computed"} end)
  end
end

defmodule AshIntrospection.Test.LoadRestrictions.PrefixedTitle do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, %{arguments: %{prefix: prefix}}) do
    Enum.map(records, fn record -> prefix <> to_string(record.title) end)
  end
end

defmodule AshIntrospection.Test.LoadRestrictions.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource AshIntrospection.Test.LoadRestrictions.Author
    resource AshIntrospection.Test.LoadRestrictions.Article
    resource AshIntrospection.Test.LoadRestrictions.Comment
  end
end

defmodule AshIntrospection.Test.LoadRestrictions.Author do
  @moduledoc false
  use Ash.Resource,
    domain: AshIntrospection.Test.LoadRestrictions.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  relationships do
    has_many :articles, AshIntrospection.Test.LoadRestrictions.Article, public?: true
  end

  aggregates do
    count :article_count, :articles, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshIntrospection.Test.LoadRestrictions.Comment do
  @moduledoc false
  use Ash.Resource,
    domain: AshIntrospection.Test.LoadRestrictions.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :body, :string, public?: true
    attribute :weight, :integer, public?: true
    attribute :article_id, :uuid, public?: true
  end

  relationships do
    belongs_to :article, AshIntrospection.Test.LoadRestrictions.Article, public?: true
  end

  calculations do
    calculate :score, :integer, expr(weight * 2), public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshIntrospection.Test.LoadRestrictions.Article do
  @moduledoc """
  The resource the load-restriction tests select fields from. It carries one
  field of every category that appends to the Ash load statement — a
  relationship, a plain calculation, a calculation returning an embedded
  resource, a calculation with arguments, an aggregate reachable through a
  relationship, an embedded attribute and a union attribute — so a test can
  reach each append site through `FieldSelector.process/4`.
  """
  use Ash.Resource,
    domain: AshIntrospection.Test.LoadRestrictions.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
    attribute :author_id, :uuid, public?: true
    attribute :meta, AshIntrospection.Test.LoadRestrictions.Meta, public?: true

    attribute :extra, :union,
      public?: true,
      constraints: [
        types: [
          meta: [type: AshIntrospection.Test.LoadRestrictions.Meta]
        ]
      ]
  end

  relationships do
    belongs_to :author, AshIntrospection.Test.LoadRestrictions.Author, public?: true
    has_many :comments, AshIntrospection.Test.LoadRestrictions.Comment, public?: true
  end

  calculations do
    calculate :slug, :string, expr(title), public?: true

    calculate :computed_meta,
              AshIntrospection.Test.LoadRestrictions.Meta,
              AshIntrospection.Test.LoadRestrictions.ComputedMeta,
              public?: true

    calculate :prefixed_title,
              :string,
              AshIntrospection.Test.LoadRestrictions.PrefixedTitle do
      public? true
      argument :prefix, :string, allow_nil?: false
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
