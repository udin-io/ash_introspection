# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.EmbeddedNote do
  @moduledoc """
  Embedded resource reachable only through a member of a NewType-wrapped union.

  Nothing else in the test suite references it, so discovering it proves that
  traversal unwrapped `AshIntrospection.Test.WrappedContent` before reading its
  `:types` constraint.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute(:body, :string, public?: true)
  end
end

defmodule AshIntrospection.Test.WrappedContent do
  @moduledoc """
  A NewType over a union. The union's `:types` constraint lives on the NewType,
  not on the wrapper, so any traversal that reads the raw constraints of
  `WrappedContent` sees an empty keyword list and misses every member.
  """
  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [
        note: [type: AshIntrospection.Test.EmbeddedNote],
        plain: [type: :string]
      ]
    ]
end

defmodule AshIntrospection.Test.EmbeddedAttachment do
  @moduledoc """
  Embedded resource reachable only as the direct type of a generic action
  argument — never through an attribute, a calculation or an aggregate.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute(:filename, :string, public?: true)
  end
end

defmodule AshIntrospection.Test.EmbeddedFilter do
  @moduledoc """
  Embedded resource reachable only as the type of a calculation argument.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute(:term, :string, public?: true)
  end
end

defmodule AshIntrospection.Test.EmbeddedAudit do
  @moduledoc """
  Embedded resource reachable only as the type of a read action's metadata.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute(:actor_label, :string, public?: true)
  end
end

defmodule AshIntrospection.Test.EmbeddedRendered do
  @moduledoc """
  Embedded resource reachable only as a generic action's `:returns` type.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute(:html, :string, public?: true)
  end
end

defmodule AshIntrospection.Test.EmbeddedUnscoped do
  @moduledoc """
  Embedded resource reachable from `AshIntrospection.Test.Ledger`'s attributes
  and from nothing else, so it is out of reach of any entrypoint set that
  declares only Ledger's generic action.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute(:note, :string, public?: true)
  end
end

defmodule AshIntrospection.Test.WrappedUser do
  @moduledoc """
  A NewType over `Ash.Type.Struct`. Its `:instance_of` constraint is invisible
  on the wrapper, so an argument typed with it hides `Test.User` from any
  scan that reads raw constraints.
  """
  use Ash.Type.NewType,
    subtype_of: :struct,
    constraints: [instance_of: AshIntrospection.Test.User]
end

defmodule AshIntrospection.Test.DiscoveryDomain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(AshIntrospection.Test.Document)
    resource(AshIntrospection.Test.Ledger)
  end
end

defmodule AshIntrospection.Test.Ledger do
  @moduledoc """
  Resource whose only embedded type hangs off an attribute. Declaring just its
  generic action as an entrypoint must leave that type undiscovered; declaring
  a read action must reach it.
  """
  use Ash.Resource,
    domain: AshIntrospection.Test.DiscoveryDomain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key(:id)
    attribute(:trail, AshIntrospection.Test.EmbeddedUnscoped, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    action :ping, :boolean do
      run(fn _input, _context -> {:ok, true} end)
    end
  end
end

defmodule AshIntrospection.Test.Document do
  @moduledoc """
  The entrypoint resource for the type-discovery tests.

  Every embedded type it can reach is reachable through exactly one route, so a
  discovery test names both the type it expects and the defect that hides it.
  """
  use Ash.Resource,
    domain: AshIntrospection.Test.DiscoveryDomain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true)
    attribute(:content, AshIntrospection.Test.WrappedContent, public?: true)
  end

  calculations do
    calculate :summary, :string, expr(title) do
      public?(true)
      argument(:filter, AshIntrospection.Test.EmbeddedFilter)
    end
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    read :audited do
      metadata(:audit, AshIntrospection.Test.EmbeddedAudit)
    end

    action :attach, :boolean do
      argument(:attachment, AshIntrospection.Test.EmbeddedAttachment)
      argument(:author, AshIntrospection.Test.WrappedUser)

      run(fn _input, _context -> {:ok, true} end)
    end

    action :render, AshIntrospection.Test.EmbeddedRendered do
      run(fn _input, _context -> {:ok, nil} end)
    end
  end
end
