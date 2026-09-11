# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.RelPagination.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource AshIntrospection.Test.RelPagination.Library
    resource AshIntrospection.Test.RelPagination.Book
    resource AshIntrospection.Test.RelPagination.Journal
    resource AshIntrospection.Test.RelPagination.Note
  end
end

defmodule AshIntrospection.Test.RelPagination.Book do
  @moduledoc false
  use Ash.Resource,
    domain: AshIntrospection.Test.RelPagination.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
    attribute :library_id, :uuid, public?: true
  end

  actions do
    defaults [:destroy, create: :*, update: :*]

    read :read do
      primary? true
      pagination offset?: true, default_limit: 10
    end

    read :list_keyset do
      pagination keyset?: true, default_limit: 20
    end

    read :find do
      get? true
      argument :id, :uuid, allow_nil?: false
    end
  end
end

defmodule AshIntrospection.Test.RelPagination.Journal do
  @moduledoc false
  use Ash.Resource,
    domain: AshIntrospection.Test.RelPagination.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :library_id, :uuid, public?: true
  end

  actions do
    defaults [:destroy, create: :*, update: :*]

    read :read do
      primary? true
      pagination offset?: true, keyset?: true, default_limit: 15
    end
  end
end

defmodule AshIntrospection.Test.RelPagination.Note do
  @moduledoc false
  use Ash.Resource,
    domain: AshIntrospection.Test.RelPagination.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :body, :string, public?: true
    attribute :library_id, :uuid, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule AshIntrospection.Test.RelPagination.Library do
  @moduledoc """
  One `:many` relationship per pagination shape a destination read can have,
  so the decorated answer has something to be wrong about.

  `:books` takes the destination's primary read, which paginates by offset.
  `:recent_books` and `:found_books` point at the same destination and name a
  `read_action`, so the three must answer differently — that is what proves
  the relationship's own `read_action` is read rather than the primary one.
  `:journals` offers both pagination kinds.

  `:notes` looks like the "no pagination" case and is not.
  `defaults [:read]` does not mean unpaginated: Ash fills a read action's
  pagination in from what the data layer can do
  (`via_data_layer?: :data_layer_default`), ETS can do both kinds, and
  `pagination offset?: false, keyset?: false` is rejected with "Must enable
  `keyset?` or `offset?`". So `:notes` reports `:mixed`, and the only `:many`
  relationship that reports `:none` is `:found_books`, whose read is
  `get? true` — a get action carries `pagination: false`.
  """
  use Ash.Resource,
    domain: AshIntrospection.Test.RelPagination.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  relationships do
    has_many :books, AshIntrospection.Test.RelPagination.Book, public?: true

    has_many :recent_books, AshIntrospection.Test.RelPagination.Book,
      public?: true,
      read_action: :list_keyset

    has_many :journals, AshIntrospection.Test.RelPagination.Journal, public?: true
    has_many :notes, AshIntrospection.Test.RelPagination.Note, public?: true

    has_many :found_books, AshIntrospection.Test.RelPagination.Book,
      public?: true,
      read_action: :find
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
